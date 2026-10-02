require "pg"
require "securerandom"
require_relative "../persistence/pg"
require_relative "errors"
require_relative "listeners"

module Monk
  module WebSocket
    # Cross-process fan-out for Registry, opt-in: require
    # "monk/websocket/pg_fanout" explicitly -- "monk/websocket" alone does
    # not load this. A second implementation of the exact interface
    # RedisFanout wraps a Registry behind (#register, #unregister, #count,
    # #broadcast, #listen!, docs/design/live-pg-fanout.md,
    # docs/history/plan-live-pg-fanout.md), so an app swaps which object it
    # holds and nothing else changes. Uses Postgres LISTEN/NOTIFY instead
    # of Redis pub/sub -- for an app that already runs Postgres
    # (persistence, Monk::Auth) and doesn't need Redis's higher throughput
    # or its lack of a payload cap (see the design doc's "Where this is
    # worse than Redis").
    class PgFanout
      # Postgres has no pattern LISTEN (unlike Redis's own
      # psubscribe("monk:ws:*")), so every key shares one fixed channel;
      # the key rides inside the notification payload instead of the
      # channel name -- see the subscriber Ractor in #initialize below
      # for the other half of this.
      CHANNEL = "monk_live".freeze

      # Postgres's own hard limit on a single NOTIFY payload -- verified
      # directly against a real server (not assumed from documentation):
      # 7999 bytes succeeds, exactly 8000 fails with "payload string too
      # long". #broadcast checks the full envelope (origin + key + app
      # payload) against this *exclusive* bound before ever calling
      # pg_notify, so an oversized broadcast fails with a clear
      # PayloadTooLargeError instead of a raw PG::Error surfacing from
      # inside the query.
      MAX_NOTIFY_PAYLOAD_BYTES = 8000

      # Inverse of #envelope_for. A class method, not a private instance
      # method like its encode-side counterpart: the subscriber Ractor
      # below has no `self` bound to a PgFanout instance to call an
      # ordinary method on, only whatever it can reach off the class
      # constant (mirrors Monk::WebSocket::Server.serve being a class
      # method for the equivalent reason -- the Server instance itself
      # never crosses into a connection's Ractor either).
      def self.decode_envelope(raw)
        bytes = raw.b
        origin_len_str, rest = bytes.split(":", 2)
        origin_len = origin_len_str.to_i
        origin = rest[0, origin_len]
        rest = rest[origin_len..]
        key_len_str, rest = rest.split(":", 2)
        key_len = key_len_str.to_i
        key = rest[0, key_len]
        payload = rest[key_len..]
        [origin, key, payload]
      end

      # The body of #listen!'s subscriber Ractor. A class method, like
      # .decode_envelope, because the Ractor has no PgFanout instance to
      # call into. Reports :ok, or why it couldn't LISTEN, on `ready`, then
      # relays notifies for the rest of the process's life.
      #
      # A dropped LISTEN connection (a Postgres restart, a failover) is
      # reconnected with backoff (plan-pg-reconnect.md). Notifies sent
      # while it was down are lost, so once listening again every open
      # socket is closed (Listeners::MISSED_CODE), and each client
      # reconnects and resyncs; their jittered reconnect spreads the
      # refetches.
      def self.subscribe(registry, pg_opts, own_origin, ready)
        begin
          conn = listen_connection(pg_opts)
        rescue StandardError => e
          ready.send("#{e.class}: #{e.message}")
          return
        end
        ready.send(:ok)

        loop do
          conn.wait_for_notify { |_channel, _pid, raw| relay(registry, own_origin, raw) }
        rescue PG::ConnectionBad => e
          log(:error, "lost the LISTEN connection (#{e.message.lines.first&.strip}); reconnecting")
          conn = reconnect(pg_opts)
          closed = registry.close_all(Listeners::MISSED_CODE, Listeners::MISSED_REASON)
          log(:info, "listening again; closed #{closed} socket(s) so their pages resync")
        end
      end

      # One notify into this process's registry. Anything that goes wrong
      # here (a payload that isn't an envelope, a failing broadcast) drops
      # this notify only: escaping, it would end the subscriber Ractor, and
      # with it every later broadcast, silently.
      def self.relay(registry, own_origin, raw)
        sender, key, payload = decode_envelope(raw)
        return if sender == own_origin

        registry.broadcast(key.to_sym, payload)
      rescue StandardError => e
        log(:error, "dropped a notify: #{e.class}: #{e.message}")
      end

      def self.listen_connection(pg_opts)
        conn = PG.connect(connect_timeout: Monk::Persistence::Pg::DEFAULT_CONNECT_TIMEOUT, **pg_opts)
        conn.exec("LISTEN #{CHANNEL}")
        conn
      rescue StandardError
        conn&.close
        raise
      end

      def self.reconnect(pg_opts)
        delay = Listeners::RETRY_INITIAL
        begin
          listen_connection(pg_opts)
        rescue PG::Error => e
          log(:warn, "can't LISTEN yet (#{e.class}: #{e.message.lines.first&.strip}); retrying in #{delay}s")
          sleep delay
          delay = Listeners.next_delay(delay)
          retry
        end
      end

      def self.log(level, message) = Listeners.log(name, level, message)
      private_class_method :relay, :listen_connection, :reconnect, :log

      # The body of a pooled publish (#broadcast with db_pool:), run in the
      # pool's worker on its connection. That connection serves nothing
      # but pool calls, each of which ends its transaction, so a NOTIFY
      # here is never held back by an app's open transaction.
      def self.notify(db, envelope)
        Monk::Persistence::Pg.checkout(db) { |conn| conn.exec_params("SELECT pg_notify($1, $2)", [CHANNEL, envelope]) }
        nil
      end

      # pg_opts: connects the publisher (one connection per Ractor that
      # publishes) and #listen!'s LISTEN connection. db_pool: (a
      # Monk::Persistence::Pg pool of size 1, docs/history/plan-pg-pool.md)
      # publishes through that pool instead, so a process holds one
      # publishing connection however many Ractors publish, and LISTENs on
      # the pool's database. Exactly one of the two.
      #
      # Through the pool a publish doesn't wait for Postgres (call_async):
      # a failed pg_notify is logged, not raised, and the page catches up
      # at its next resync, as it would after any missed patch. Size 1
      # because only a single worker runs one sender's publishes in the
      # order they were made, and patches to a page must arrive in order.
      def initialize(registry, pg_opts: nil, db_pool: nil)
        # Checked upfront, on the argument -- RedisFanout has no equivalent
        # check (freezing self never raises on its own, even when an ivar
        # isn't itself shareable), so a bad registry there only surfaces
        # later as an opaque Ractor::IsolationError. Mirrors
        # Monk::Live.configure's own check of its registry argument.
        unless Ractor.shareable?(registry)
          raise ArgumentError,
            "Monk::WebSocket::PgFanout.new needs a Ractor-shareable registry, got #{registry.class}"
        end

        @registry = registry
        # Ractor.make_shareable, not a plain #freeze: pg_opts's values
        # (host/user/password Strings from ENV.fetch, typically) aren't
        # frozen individually just because the Hash itself is -- #freeze
        # only locks the Hash against further key/value changes, it
        # doesn't recurse. Without this, the shareability check below
        # fails on this Hash's contents, not on the registry argument it's
        # meant to guard, the same trap Server#initialize's
        # allowed_origins already avoids the same way.
        raise ArgumentError, "Monk::WebSocket::PgFanout.new needs pg_opts: or db_pool:, not both" if pg_opts && db_pool
        raise ArgumentError, "Monk::WebSocket::PgFanout.new needs pg_opts: or db_pool:" unless pg_opts || db_pool

        @pg_opts = Ractor.make_shareable((pg_opts || pooled_pg_opts(db_pool)).dup)
        @db_pool = db_pool
        @db = db_pool && Monk::Persistence::Pg.pool_config(db_pool).db
        # Frozen explicitly, not just a String literal: read from every
        # calling Ractor's own #broadcast and from the subscriber Ractor
        # #listen! starts, both of which raise Ractor::IsolationError on an
        # unfrozen value -- same reason RedisFanout freezes its own
        # @origin.
        @origin = SecureRandom.uuid.freeze

        freeze
      end

      # Starts relaying other processes' broadcasts into this process's
      # registry: a subscriber Ractor with its own LISTEN connection. Only
      # the process that holds sockets calls this (bin/websocket_server, at
      # boot, from the main Ractor) -- a publish-only process (bin/server,
      # bin/jobs) never does, so it holds no LISTEN connection at all.
      # Returns once the LISTEN is in effect, so nothing notified after it
      # can be missed; raises ListenError if Postgres can't be reached.
      # Calling it again is a no-op.
      def listen!
        return self if Listeners.listening?(@origin)

        ready = Ractor::Port.new
        # Ractor.new's block args must be shareable: registry is
        # (Registry freezes itself around a Ractor, which is inherently
        # shareable), @pg_opts and @origin are already made so, a Port
        # always is. The PG::Connection itself is never passed in --
        # opened fresh inside the block, mirroring RedisFanout's
        # subscriber and Monk::Persistence::Pg's per-Ractor connection
        # pattern.
        Ractor.new(@registry, @pg_opts, @origin, ready) do |registry, pg_opts, own_origin, ready|
          Monk::WebSocket::PgFanout.subscribe(registry, pg_opts, own_origin, ready)
        end

        result = ready.receive
        raise ListenError, "Monk::WebSocket::PgFanout#listen! couldn't LISTEN: #{result}" unless result == :ok

        Listeners.add(@origin)
        self
      end

      def register(key, port)
        unless Listeners.listening?(@origin)
          raise NotListeningError,
            "Monk::WebSocket::PgFanout#register before #listen!: this socket would never get " \
            "other processes' broadcasts -- call listen! once at boot in the process that holds " \
            "sockets (bin/websocket_server: Monk::Live.listen!)"
        end

        @registry.register(key, port)
      end

      def unregister(key, port) = @registry.unregister(key, port)
      def count(key) = @registry.count(key)

      def broadcast(key, payload)
        # Delivers locally first, regardless of what happens next -- same
        # latency and reliability as a plain Registry if Postgres is
        # briefly unavailable or this payload is over the wire cap,
        # mirroring RedisFanout#broadcast's own ordering.
        @registry.broadcast(key, payload)

        envelope = envelope_for(key, payload)
        if envelope.bytesize >= MAX_NOTIFY_PAYLOAD_BYTES
          raise Monk::WebSocket::PayloadTooLargeError,
            "Monk::WebSocket::PgFanout#broadcast payload plus origin/key framing is " \
            "#{envelope.bytesize} bytes; Postgres NOTIFY accepts a payload of at most " \
            "#{MAX_NOTIFY_PAYLOAD_BYTES - 1} bytes -- shrink the fragment, or use " \
            "Monk::WebSocket::RedisFanout instead, which has no such cap"
        end

        # pg_notify(channel, payload), not a string-built
        # "NOTIFY channel, 'payload'" -- passing the envelope as a bound
        # parameter sidesteps any quoting/injection concern for its bytes
        # entirely, unlike Redis's PUBLISH, which never had that concern
        # in the first place.
        return Monk::Persistence::Pg.pool(@db_pool).call_async(PgFanout, :notify, @db, envelope) if @db_pool

        publisher.exec_params("SELECT pg_notify($1, $2)", [CHANNEL, envelope])
      end

      private

      # The pool's database's connection options, for #listen!.
      def pooled_pg_opts(db_pool)
        config = Monk::Persistence::Pg.pool_config(db_pool)
        unless config.size == 1
          raise ArgumentError,
            "Monk::WebSocket::PgFanout's db_pool #{db_pool.inspect} has size #{config.size}; it must have size 1: " \
            "patches to a page must arrive in the order they were published, and only one worker keeps " \
            "a sender's publishes in order"
        end
        Monk::Persistence::Pg.connection_options(config.db)
      end

      # Length-prefixes the origin and key (Netstring-style: "<bytesize>:"
      # then that many bytes) instead of RedisFanout's NUL-separated
      # "origin\0payload" -- discovered while building this that a NUL
      # byte can't ride in a Postgres NOTIFY payload at all (a bound text
      # parameter containing one raises "string contains null byte" from
      # inside exec_params; text NOTIFY payloads simply don't carry one).
      # A digit run followed by ':' can never be confused with content
      # coming later: the header is always the *first* ':' in the whole
      # string, no matter what colons, NULs or anything else an app's key
      # or payload contains.
      #
      # Forces binary (.b) throughout so slicing by the recorded byte
      # lengths lines up exactly -- the same fix Monk::WebSocket::Frame.encode
      # needed for non-ASCII payloads (docs/history/plan-live.md Phase 7);
      # a String#[] by character count on a UTF-8 string would misalign
      # the moment origin/key/payload aren't pure ASCII.
      def envelope_for(key, payload)
        origin_bytes = @origin.b
        key_bytes = key.to_s.b
        "#{origin_bytes.bytesize}:".b + origin_bytes + "#{key_bytes.bytesize}:".b + key_bytes + payload.to_s.b
      end

      # One PG::Connection per calling Ractor, opened on first use and
      # cached there -- a single client called concurrently from every
      # connection Ractor's #broadcast wouldn't be safe, mirrors
      # RedisFanout#publisher and Monk::Persistence::Pg's own per-Ractor
      # pattern exactly. Never the connection Monk::Persistence::Pg hands
      # out for app queries: NOTIFY issued on a connection mid-transaction
      # wouldn't fire until that transaction commits, so this stays a
      # connection of its own, used for nothing but one-off notifies.
      #
      # Probed before each notify and reset if Postgres dropped it
      # (Monk::Persistence::Pg.alive?, plan-pg-reconnect.md), the way
      # checkout treats an app's connection. A failed pg_notify is never
      # retried: it may have reached the server, and a patch delivered
      # twice shows twice, while a missed one is recovered by the client's
      # resync.
      def publisher
        conn = Ractor.current[:monk_pg_fanout_publisher] ||= connect
        Monk::Persistence::Pg.revive(conn) unless Monk::Persistence::Pg.alive?(conn)
        conn
      end

      # Same connect_timeout default as Monk::Persistence::Pg's own
      # connections: a reset runs inside a request's Live.patch, and
      # mustn't wait indefinitely for a host that doesn't answer.
      def connect
        PG.connect(connect_timeout: Monk::Persistence::Pg::DEFAULT_CONNECT_TIMEOUT, **@pg_opts)
      end
    end
  end
end
