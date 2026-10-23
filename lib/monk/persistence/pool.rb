module Monk
  module Persistence
    # Named connection pools for short-lived Ractors
    # (docs/history/plan-pg-pool.md). A PG::Connection can't be moved or
    # shared across Ractors, so a pool lends nothing: a few worker Ractors
    # own connections, and other Ractors send them calls to run.
    #
    #   caller --[:call, receiver, method, args, kwargs, reply, deadline]--> dispatcher's inbox
    #   dispatcher --> an idle worker (or the queue, until one is idle)
    #   worker: receiver.public_send(method, *args, **kwargs), on its own connection
    #   worker --[:ok, value] or [:error, exception]--> reply; [:idle, port] --> inbox
    #
    # The dispatcher starts the workers and replaces one that dies.
    module Pool
      # A pool as declared with Registry#pool(name, ...). Frozen, so any
      # Ractor can read it once boot has frozen the registry.
      Config = Data.define(:name, :db, :size, :timeout, :queue)

      # What #pool fills in for options a declaration leaves out. timeout:
      # is the same 5 s as checkout's. queue: is how many calls may wait
      # for a worker before #call refuses more: 4 workers clear 1000 in
      # well under a second, so a full queue means a stalled database.
      DEFAULTS = { db: :primary, size: 4, timeout: 5, queue: 1000 }.freeze

      # Monk::Log writes to log/<env>.log once Monk has booted. A worker
      # mustn't die of a failure to log, whatever state Monk::Log is in.
      def self.log(level, message)
        Monk::Log.public_send(level, "Monk::Persistence #{message}")
      rescue StandardError
        nil
      end

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
        #
        # Raises Monk::PoolWorkerDiedError at once if the worker running it
        # dies, and Monk::PoolStoppedError if the pool stops first.
        #
        # Made from inside one of this pool's own workers, it runs inline,
        # on that worker's connection: queued, it could wait for the very
        # worker making it.
        def call(receiver, method, *args, **kwargs)
          return receiver.public_send(method, *args, **kwargs) if Ractor.current[:monk_pool] == config.name

          reply = Ractor::Port.new
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + config.timeout
          submit([:call, receiver, method, args, kwargs, reply, deadline])
          status, value = reply.receive
          case status
          when :ok then value
          when :error then raise_from_worker(value)
          when :timeout then raise Monk::PersistenceTimeoutError, timeout_message(receiver, method)
          when :full then raise Monk::PoolFullError, full_message
          when :died then raise Monk::PoolWorkerDiedError, died_message(receiver, method)
          when :stopped then raise Monk::PoolStoppedError, stopped_message
          end
        ensure
          reply&.close
        end

        # Like #call, but returns nil as soon as the dispatcher has the call
        # (microseconds), without waiting for it to run. Raises
        # Monk::PoolFullError when the queue is full. The call has no
        # deadline: it always runs, however long it waits. A failure while
        # it runs is logged, since nobody is waiting for it.
        #
        # One sender's calls run in the order it made them only in a pool
        # of size 1; a larger pool runs them side by side.
        def call_async(receiver, method, *args, **kwargs)
          ack = Ractor::Port.new
          submit([:call, receiver, method, args, kwargs, ack, nil])
          status, = ack.receive
          raise Monk::PoolFullError, full_message if status == :full
          raise Monk::PoolStoppedError, stopped_message if status == :stopped

          nil
        ensure
          ack&.close
        end

        private

        # The dispatcher's inbox closes when it ends.
        def submit(call)
          inbox.send(call)
        rescue Ractor::ClosedError
          raise Monk::PoolStoppedError, stopped_message
        end

        def died_message(receiver, method)
          "the pool #{config.name.inspect} worker running #{receiver}.#{method} died; " \
            "the call may or may not have finished (the worker has been replaced)"
        end

        def stopped_message = "pool #{config.name.inspect} has stopped"

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
      #
      # It starts the workers, and watches them: one that dies is logged
      # and replaced at once, and its caller answered :died. A replacement
      # that can't connect is retried with backoff, calls waiting in the
      # queue meanwhile. It is never restarted itself, since every handle,
      # possibly kept in a constant, holds its inbox: it survives a
      # failure handling a message, and if it ends anyway, it answers
      # every caller still waiting :stopped, so none hangs.
      class Dispatcher
        RETRY_INITIAL = 0.5
        RETRY_MAX = 30

        # Reports [:ok, inbox] on `ready` once every worker has connected,
        # or [:error, why] after stopping them.
        def self.run(backend, config, ready)
          dispatcher = new(backend, config, Ractor::Port.new)
          failure = dispatcher.start_workers
          return dispatcher.report_failure(ready, failure) if failure

          ready.send([:ok, dispatcher.inbox])
          dispatcher.run
        end

        attr_reader :inbox

        def initialize(backend, config, inbox)
          @backend = backend
          @config = config
          @inbox = inbox
          @workers = {} # index => { ractor:, port:, failure: }
          @idle = []
          @waiting = []
          @running = {} # worker port => its call, or nil once its caller timed out
          @retry_delay = {} # index => seconds before the next attempt
          @respawn_at = {} # index => when to try again
        end

        # Blocks until each worker has connected or failed to; returns the
        # first failure, or nil.
        def start_workers
          @config.size.times { |index| spawn_worker(index) }
          pending = @config.size
          failure = nil
          while pending.positive?
            message = @inbox.receive
            case message.first
            when :ready then ready(*message.drop(1))
            when :failed then failure ||= message[2]
            when :idle then @idle.push(message[1])
            end
            pending -= 1 if %i[ready failed].include?(message.first)
          end
          failure
        end

        def report_failure(ready, failure)
          stop_workers
          ready.send([:error, failure])
        end

        def run
          ticker = start_ticker
          loop do
            message = @inbox.receive
            break if message.first == :stop

            handle(message)
            dispatch
          rescue StandardError => e
            log(:error, "dispatcher: #{e.class}: #{e.message}; carrying on")
          end
        ensure
          ticker&.kill
          stop_workers
          release_callers
        end

        private

        def handle(message)
          case message.first
          when :call then accept(message)
          when :idle then idle(message[1])
          when :tick then tick
          when :ready then ready(*message.drop(1))
          when :failed then @workers[message[1]]&.store(:failure, message[2])
          when :died then died(*message.drop(1))
          end
        end

        # A call message: [:call, receiver, method, args, kwargs, reply,
        # deadline]. An async call has no deadline, and its reply port only
        # hears whether it was accepted.
        def reply_of(call) = call[5]
        def deadline_of(call) = call[6]
        def describe(call) = "#{call[1]}.#{call[2]}"

        def accept(call)
          return answer(call, [:full]) if @waiting.size >= @config.queue

          @waiting.push(call)
          answer(call, [:accepted]) unless deadline_of(call)
        end

        def past?(call, now)
          deadline = deadline_of(call)
          deadline && deadline < now
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

        def tick
          now = monotonic
          expire(now)
          due = @respawn_at.select { |_, at| at <= now }.keys
          due.each do |index|
            @respawn_at.delete(index)
            spawn_worker(index)
          end
        end

        def expire(now)
          expired, @waiting = @waiting.partition { |call| past?(call, now) }
          expired.each { |call| answer(call, [:timeout]) }
          @running.each do |worker, call|
            next unless call && past?(call, now)

            answer(call, [:timeout])
            @running[worker] = nil
          end
        end

        def spawn_worker(index)
          ractor = Ractor.new(@backend, @config, @inbox, index, name: "monk-pool-#{@config.name}-#{index}") do |*args|
            Monk::Persistence::Pool::Worker.run(*args)
          end
          @workers[index] = { ractor: ractor, port: nil, failure: nil }
          watch(index, ractor)
        end

        def ready(index, port)
          worker = @workers[index]
          return unless worker

          log(:info, "worker #{index} connected again") if @retry_delay.delete(index)
          worker[:port] = port
        end

        # A thread per worker turns its Ractor ending into a message here.
        def watch(index, ractor)
          inbox = @inbox
          Thread.new do
            port = Ractor::Port.new
            ractor.monitor(port)
            inbox.send([:died, index, ractor, port.receive])
          rescue Ractor::ClosedError
            nil
          end
        end

        def died(index, ractor, reason)
          worker = @workers[index]
          return if @stopping || worker.nil? || !worker[:ractor].equal?(ractor)

          port = worker[:port]
          return retry_later(index, worker[:failure]) unless port

          @idle.delete(port)
          call = @running.delete(port)
          doing = call ? "running #{describe(call)}" : "idle"
          log(:error, "worker #{index} died (#{reason}) while #{doing}, starting a new one: #{worker[:failure]}")
          answer(call, [:died]) if call && deadline_of(call)
          spawn_worker(index)
        end

        def retry_later(index, failure)
          delay = @retry_delay[index] || RETRY_INITIAL
          log(:warn, "worker #{index} couldn't connect (#{failure}); retrying in #{delay}s")
          @retry_delay[index] = [delay * 2, RETRY_MAX].min
          @respawn_at[index] = monotonic + delay
        end

        # Every worker finishes the call in hand first. Two loops: all are
        # told before any is waited for, so they stop side by side.
        def stop_workers
          @stopping = true
          @workers.each_value do |worker|
            worker[:port]&.send(:stop)
          rescue Ractor::ClosedError
            nil
          end
          @workers.each_value { |worker| worker[:ractor].join } # rubocop:disable Style/CombinableLoops
        end

        def release_callers
          (@waiting + @running.values.compact).each { |call| answer(call, [:stopped]) }
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

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        def log(level, message) = Pool.log(level, "pool #{@config.name.inspect}: #{message}")
      end

      # The body of a pool's worker Ractor: an ordinary Ractor whose
      # connection the ordinary checkout opens and keeps, with its
      # reconnect and rollback. A called method's own checkout gets it.
      module Worker
        def self.run(backend, config, inbox, index)
          # The dispatcher logs why a worker died, from what it sends
          # below; don't also dump it to stderr.
          Thread.current.report_on_exception = false
          Ractor.current[:monk_pool] = config.name
          port = Ractor::Port.new
          begin
            backend.checkout(config.db) { nil }
          rescue StandardError => e
            return inbox.send([:failed, index, "#{e.class}: #{e.message}"])
          end
          inbox.send([:ready, index, port])

          loop do
            inbox.send([:idle, port])
            call = port.receive
            break if call == :stop

            _, receiver, method, args, kwargs, reply, deadline = call
            next perform_async(config, receiver, method, args, kwargs) unless deadline

            perform(backend, receiver, method, args, kwargs, reply)
          end
        rescue Ractor::ClosedError
          nil # the dispatcher has stopped
        rescue Exception => e # rubocop:disable Lint/RescueException
          # Not a called method's StandardError (its caller gets those): a
          # bug, or an Exception from deep in a C extension. Tell the
          # dispatcher why, then end: it starts a new worker.
          report_death(inbox, index, e)
          raise
        ensure
          backend.disconnect_all
        end

        def self.report_death(inbox, index, error)
          trace = Array(error.backtrace).first(5).map { |frame| "\n  #{frame}" }.join
          inbox.send([:failed, index, "#{error.class}: #{error.message}#{trace}"])
        rescue Ractor::ClosedError
          nil
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

        # Nobody waits for an async call's result: only its failure is
        # reported, in the log.
        def self.perform_async(config, receiver, method, args, kwargs)
          receiver.public_send(method, *args, **kwargs)
        rescue StandardError => e
          trace = Array(e.backtrace).first(10).map { |frame| "\n  #{frame}" }.join
          what = "#{receiver}.#{method} failed: #{e.class}: #{e.message}"
          Pool.log(:error, "pool #{config.name.inspect}: #{what}#{trace}")
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
