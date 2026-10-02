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
        #
        # Raises Monk::PersistenceTimeoutError once the pool's timeout
        # passes, whether the call is still queued (it then never runs) or
        # running (it runs to the end: a timeout undoes nothing). Raises
        # Monk::PoolFullError at once when the pool's queue is full.
        def call(receiver, method, *args, **kwargs)
          reply = Ractor::Port.new
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + config.timeout
          inbox.send([:call, receiver, method, args, kwargs, reply, deadline])
          status, value = reply.receive
          case status
          when :ok then value
          when :error then raise_from_worker(value)
          when :timeout then raise Monk::PersistenceTimeoutError, timeout_message(receiver, method)
          when :full then raise Monk::PoolFullError, full_message
          end
        ensure
          reply&.close
        end

        private

        # The worker's frames, then the caller's: a port drops a
        # backtrace, so the worker sent its own as strings.
        def raise_from_worker(error)
          error.set_backtrace([*error.backtrace, "(in pool #{config.name.inspect}; called from)", *caller(2)])
          raise error
        end

        def timeout_message(receiver, method)
          "#{receiver}.#{method} in pool #{config.name.inspect} didn't finish within #{config.timeout}s " \
            "(if it was already running, it runs to the end: a timeout undoes nothing)"
        end

        def full_message
          "pool #{config.name.inspect} already has #{config.queue} calls waiting for its " \
            "#{config.size} worker(s): the database is stalled, or the pool is too small"
        end
      end

      # A pool's dispatcher, inside its own Ractor. It exists because a
      # port can only be read by the Ractor that created it: the workers
      # can't share an inbox, so this one holds it, with the idle workers,
      # the calls waiting for one, and the calls running.
      #
      # Timeouts are its job too: a ticker wakes it, and it answers
      # :timeout to every caller whose deadline has passed, so a caller
      # needs no timer of its own. A queued call that timed out is dropped
      # and never runs.
      class Dispatcher
        def self.run(config, ready)
          inbox = Ractor::Port.new
          ready.send(inbox)
          new(config, inbox).run
        end

        def initialize(config, inbox)
          @config = config
          @inbox = inbox
          @idle = []
          @waiting = []
          @running = {} # worker port => its call, or nil once its caller timed out
        end

        def run
          ticker = start_ticker
          loop do
            message = @inbox.receive
            case message.first
            when :call then accept(message)
            when :idle then idle(message[1])
            when :tick then expire
            when :stop then break
            end
            dispatch
          end
        ensure
          ticker&.kill
        end

        private

        # A call message: [:call, receiver, method, args, kwargs, reply, deadline].
        def reply_of(call) = call[5]
        def deadline_of(call) = call[6]

        def accept(call)
          return answer(call, [:full]) if @waiting.size >= @config.queue

          @waiting.push(call)
        end

        def idle(worker)
          @running.delete(worker)
          @idle.push(worker)
        end

        # Oldest call first. A worker whose port is closed is dropped, and
        # the call waits for the next one.
        def dispatch
          while @idle.any? && @waiting.any?
            worker = @idle.pop
            call = @waiting.first
            next unless hand(worker, call)

            @waiting.shift
            @running[worker] = call
          end
        end

        def expire
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          expired, @waiting = @waiting.partition { |call| deadline_of(call) < now }
          expired.each { |call| answer(call, [:timeout]) }
          @running.each do |worker, call|
            next unless call && deadline_of(call) < now

            answer(call, [:timeout])
            @running[worker] = nil
          end
        end

        def start_ticker
          interval = (@config.timeout / 10.0).clamp(0.01, 0.1)
          inbox = @inbox
          Thread.new do
            loop do
              sleep interval
              inbox.send([:tick])
            end
          rescue Ractor::ClosedError
            nil
          end
        end

        def answer(call, message)
          reply_of(call).send(message)
        rescue Ractor::ClosedError
          nil # the caller stopped waiting
        end

        # False when the worker's port is closed (the worker ended).
        def hand(worker, call)
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

            _, receiver, method, args, kwargs, reply = call
            perform(backend, receiver, method, args, kwargs, reply)
          end
        rescue Ractor::ClosedError
          nil # the dispatcher has stopped
        ensure
          backend.disconnect_all
        end

        def self.perform(backend, receiver, method, args, kwargs, reply)
          result =
            begin
              [:ok, receiver.public_send(method, *args, **kwargs)]
            rescue StandardError => e
              [:error, Portable.exception(e, backend)]
            end
          return if deliver(reply, result)

          # The copy to the caller's Ractor failed: answer with something
          # that can always be copied, so the caller isn't left waiting.
          status, value = result
          fallback = status == :ok ? Portable.return_error(receiver, method, value) : Portable.summary(value)
          deliver(reply, [:error, fallback])
        end

        # False when the result can't be copied to the caller's Ractor.
        # Not only Ractor::Error: copying a PG::Result raises TypeError
        # ("allocator undefined"), and an escape here would end the worker
        # with its caller still waiting.
        def self.deliver(reply, result)
          reply.send(result)
          true
        rescue Ractor::ClosedError
          true # the caller stopped waiting: nothing to answer
        rescue StandardError
          false
        end
      end

      # Copies of what a worker sends back, fit to cross to the caller's
      # Ractor.
      module Portable
        # Longer cause chains are cut to a summary of the next cause.
        MAX_CAUSES = 5

        # A copy of error with its class, message, own instance variables
        # and backtrace, and its cause chain copied the same way. The
        # backend drops what can't be copied (Pg: the connection and
        # result a PG::Error holds). The backtrace is set as strings: a
        # port drops it otherwise.
        def self.exception(error, backend, depth = 0)
          copy = error.dup
          backend.make_portable(copy)
          copy.set_backtrace(Array(error.backtrace))
          return copy unless error.cause

          cause = depth < MAX_CAUSES ? exception(error.cause, backend, depth + 1) : summary(error.cause)
          with_cause(copy, cause)
        rescue StandardError
          summary(error)
        end

        # Exception has no cause=: raising sets it, and keeps the backtrace
        # already set.
        def self.with_cause(error, cause)
          raise error, cause: cause
        rescue Exception => e # rubocop:disable Lint/RescueException
          e
        end

        # For an exception that still can't be copied.
        def self.summary(error)
          RuntimeError.new("#{error.class}: #{error.message} (it couldn't leave the pool)").tap do |copy|
            copy.set_backtrace(Array(error.backtrace))
          end
        end

        def self.return_error(receiver, method, value)
          Monk::PoolReturnError.new(
            "#{receiver}.#{method} returned a #{value.class}, which can't leave the pool: " \
            "return plain data (rows as Hashes, not a PG::Result)",
          )
        end
      end
    end
  end
end
