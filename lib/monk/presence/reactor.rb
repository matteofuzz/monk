require "json"
require "pg"
require_relative "../log"
require_relative "../persistence/pg"
require_relative "store"

module Monk
  module Presence
    # bin/server's side of presence (ADR 0019): a Ractor that reacts to the
    # WebSocket processes' signals by calling the app's on_change with the
    # changed subjects' current status. Every web process starts one; only
    # the one holding a session advisory lock LISTENs, the others retry, and
    # take over when the holder's connection ends (Postgres frees the lock).
    #
    # A signal sent while no reactor listens is lost: on_change is at most
    # once, and a page catches up on its next resync.
    #
    # Plain module methods, like PgFanout.subscribe: the Ractor has no
    # instance to call into.
    module Reactor
      LOCK_SQL = "SELECT pg_try_advisory_lock(hashtext('monk_presence_reactor'))".freeze

      # Postgres learns that a reactor's host vanished (a lost node, a cut
      # network: no FIN, no RST) only when TCP keepalive gives up, after
      # about 2 hours with Linux's defaults, and until then the dead session
      # holds the lock and no web process reacts. These make it about 25 s:
      # 10 s idle, then 3 probes 5 s apart. Server settings any user may
      # set for their own session; the client-side ones in .connect do the
      # same for a reactor waiting on a Postgres host that vanished.
      KEEPALIVE_SQL = "SET tcp_keepalives_idle = 10; SET tcp_keepalives_interval = 5; " \
                      "SET tcp_keepalives_count = 3".freeze
      CLIENT_KEEPALIVES = { keepalives: 1, keepalives_idle: 10, keepalives_interval: 5, keepalives_count: 3 }.freeze

      # How often a waiting reactor checks whether it was stopped.
      POLL = 0.5

      Handle = Data.define(:ractor, :stop_port)

      # pg_opts: the database's connection options; on_change: a shareable
      # block. Returns a handle for .stop.
      #
      # One thread: a second one, waiting in Postgres, kept the Ractor
      # from handling a stop message about half the time. So the reactor
      # waits in short steps and stops once its stop port is closed.
      def self.start(pg_opts, on_change, retry_interval:)
        stop_port = Ractor::Port.new
        ractor = Ractor.new(Ractor.make_shareable(pg_opts.dup), Ractor.make_shareable(on_change), retry_interval,
          stop_port, name: "monk-presence-reactor",) do |opts, hook, interval, stop|
          Monk::Presence::Reactor.run(opts, hook, interval, stop)
        end
        Handle.new(ractor: ractor, stop_port: stop_port)
      end

      # Ends the reactor and closes its connection, which frees the lock.
      def self.stop(handle)
        handle.stop_port.close
        handle.ractor.join
      end

      def self.run(pg_opts, on_change, retry_interval, stop = nil)
        stopped = -> { stop&.closed? }
        until stopped.call
          conn = nil
          begin
            conn = connect(pg_opts)
            next unless lock_acquired?(conn, retry_interval, stopped)

            conn.exec("LISTEN #{Store::CHANNEL}")
            log(:info, "Monk::Presence: this process reacts to presence changes (pid #{Process.pid})")
            conn.wait_for_notify(POLL) { |_channel, _pid, payload| react(on_change, payload) } until stopped.call
          rescue PG::Error => e
            log(:error, "Monk::Presence reactor: #{e.class}: #{e.message.lines.first&.chomp}; " \
                        "retrying in #{retry_interval} s",)
            pause(retry_interval, stopped)
          ensure
            conn&.close
          end
        end
      end

      # The reactor's own connection, kept apart from Monk::Persistence's:
      # the lock and the LISTEN belong to its session (so not through
      # PgBouncer in transaction mode).
      def self.connect(pg_opts)
        conn = PG.connect(connect_timeout: Monk::Persistence::Pg::DEFAULT_CONNECT_TIMEOUT, **CLIENT_KEEPALIVES,
          **pg_opts,)
        conn.exec(KEEPALIVE_SQL)
        conn
      rescue PG::Error
        conn&.close
        raise
      end

      # True once this connection holds the lock; false if stopped first.
      def self.lock_acquired?(conn, retry_interval, stopped)
        until conn.exec(LOCK_SQL).getvalue(0, 0) == "t"
          pause(retry_interval, stopped)
          return false if stopped.call
        end
        true
      end

      def self.pause(seconds, stopped)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        until stopped.call || (left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)) <= 0
          sleep [left, POLL].min
        end
      end

      # One signal. Anything that goes wrong drops this signal only.
      def self.react(on_change, payload)
        on_change.call(Monk::Presence.status(JSON.parse(payload)))
      rescue StandardError => e
        log(:error, "Monk::Presence on_change failed: #{e.class}: #{e.message.lines.first&.chomp}")
      end

      # Monk::Log writes from a Ractor once Monk has booted (bin/server
      # starts the reactor after Monk.boot). Logging must never end it.
      def self.log(level, message)
        Monk::Log.public_send(level, message)
      rescue StandardError
        nil
      end
    end
  end
end
