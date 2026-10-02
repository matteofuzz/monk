module Monk
  module Persistence
    # Named connection pools for short-lived Ractors
    # (docs/history/plan-pg-pool.md). A PG::Connection can't be moved or
    # shared across Ractors, so a pool lends nothing: a few worker Ractors
    # own connections, and other Ractors send them calls to run.
    #
    #   caller --[:call, receiver, method, args, kwargs, reply]--> dispatcher's inbox
    #   dispatcher --> an idle worker (or the queue, until one is idle)
    #   worker: receiver.public_send(method, *args, **kwargs), on its own connection
    #   worker --[:ok, value] or [:error, exception]--> reply; [:idle, port] --> inbox
    module Pool
      # A pool as declared with Registry#pool(name, ...). Frozen, so any
      # Ractor can read it once boot has frozen the registry.
      Config = Data.define(:name, :db, :size, :timeout, :queue)

      # What #pool fills in for options a declaration leaves out. timeout:
      # is the same 5 s as checkout's. queue: is how many calls may wait
      # for a worker before #call refuses more: 4 workers clear 1000 in
      # well under a second, so a full queue means a stalled database.
      DEFAULTS = { db: :primary, size: 4, timeout: 5, queue: 1000 }.freeze

      # A started pool, as Registry#pool(name) returns it: frozen, so it can
      # be kept in a constant and used from any Ractor.
      Handle = Data.define(:config, :inbox) do
        # Runs receiver.public_send(method, *args, **kwargs) in one of the
        # pool's workers, on that worker's connection, and returns its
        # value or raises its exception. Everything after the method name
        # belongs to the target method: call takes no options of its own.
        def call(receiver, method, *args, **kwargs)
          reply = Ractor::Port.new
          inbox.send([:call, receiver, method, args, kwargs, reply])
          status, value = reply.receive
          raise value if status == :error

          value
        ensure
          reply&.close
        end
      end

      # The body of a pool's dispatcher Ractor. It exists because a port can
      # only be read by the Ractor that created it: the workers can't share
      # an inbox, so this one holds it, with the idle workers and the calls
      # waiting for one.
      module Dispatcher
        def self.run(ready)
          inbox = Ractor::Port.new
          ready.send(inbox)
          idle = []
          waiting = []

          loop do
            message = inbox.receive
            case message.first
            when :call
              waiting.push(message)
            when :idle
              idle.push(message[1])
            when :stop
              break
            end
            dispatch(idle, waiting)
          end
        end

        # Oldest call first. A worker whose port is closed is dropped, and
        # the call waits for the next one.
        def self.dispatch(idle, waiting)
          while idle.any? && waiting.any?
            waiting.shift if hand(idle.pop, waiting.first)
          end
        end

        # False when the worker's port is closed (the worker ended).
        def self.hand(worker, call)
          worker.send(call)
          true
        rescue Ractor::ClosedError
          false
        end
      end

      # The body of a pool's worker Ractor: an ordinary Ractor whose
      # connection the ordinary checkout opens and keeps, with its
      # reconnect and rollback. A called method's own checkout gets it.
      module Worker
        def self.run(backend, config, inbox, ready)
          Ractor.current[:monk_pool] = config.name
          port = Ractor::Port.new
          begin
            backend.checkout(config.db) { nil }
          rescue StandardError => e
            return ready.send([:error, "#{e.class}: #{e.message}"])
          end
          ready.send([:ok, port])

          loop do
            inbox.send([:idle, port])
            call = port.receive
            break if call == :stop

            perform(*call.drop(1))
          end
        rescue Ractor::ClosedError
          nil # the dispatcher has stopped
        ensure
          backend.disconnect_all
        end

        def self.perform(receiver, method, args, kwargs, reply)
          result =
            begin
              [:ok, receiver.public_send(method, *args, **kwargs)]
            rescue StandardError => e
              [:error, e]
            end
          deliver(reply, result)
        end

        # A value or exception that can't be copied to another Ractor still
        # gets the caller an answer. (Phase 3 of the plan makes PG errors
        # cross with their class.)
        def self.deliver(reply, result)
          reply.send(result)
        rescue Ractor::ClosedError
          nil # the caller stopped waiting
        rescue Ractor::Error => e
          reply.send([:error, RuntimeError.new("#{result.last.class} can't leave the pool: #{e.message}")])
        end
      end
    end
  end
end
