require "socket"
require_relative "../jobs"
require_relative "worker"

module Monk
  module Jobs
    # A job process (bin/jobs): the supervisor in the calling Ractor and N
    # worker Ractors (docs/history/plan-jobs.md Phase 6). Opt-in on its own,
    # require "monk/jobs/runtime" -- the web process only enqueues.
    #
    #   Monk::Jobs::Runtime.new(queues: %w[mailers default], workers: 5).run
    #
    # run blocks until TERM or INT (or #stop): workers finish the job in
    # hand, up to shutdown_timeout seconds, and whatever is still running
    # then is released for another process.
    class Runtime
      DEFAULTS = {
        queues: [Job::DEFAULT_QUEUE], workers: 5, poll_interval: 1.0, tick_interval: 1.0,
        heartbeat_interval: 15, process_timeout: 120, shutdown_timeout: 25,
      }.freeze

      # queues: claimed in this order, so earlier ones go first.
      # poll_interval: seconds an idle worker waits before claiming again.
      # tick_interval: seconds between the supervisor's rounds of staging
      #   due jobs (so also how late a scheduled job can start).
      # heartbeat_interval: seconds between this process's heartbeats, and
      #   between its looks for dead processes to prune.
      # process_timeout: seconds of silence after which another process's
      #   running jobs are released.
      # shutdown_timeout: seconds a stop waits for jobs in flight.
      def initialize(**settings)
        unknown = settings.keys - DEFAULTS.keys
        raise ArgumentError, "unknown Monk::Jobs::Runtime setting(s): #{unknown.join(", ")}" if unknown.any?

        settings = DEFAULTS.merge(settings)
        @queues = checked_queues(settings[:queues])
        @worker_count = settings[:workers]
        unless positive_integer?(@worker_count)
          raise ArgumentError, "workers must be a positive Integer, got #{@worker_count.inspect}"
        end

        %i[poll_interval tick_interval heartbeat_interval process_timeout shutdown_timeout].each do |name|
          value = settings[name]
          unless value.is_a?(Numeric) && value.positive?
            raise ArgumentError, "#{name} must be a positive number of seconds, got #{value.inspect}"
          end

          instance_variable_set(:"@#{name}", value)
        end
        @stopping = false
      end

      def run(trap_signals: true)
        Monk.freeze!
        @adapter = Monk::Jobs.adapter
        @hostname = Socket.gethostname
        @pid = Process.pid
        @process_id = @adapter.register_process(hostname: @hostname, pid: @pid)
        trap_signals! if trap_signals

        @monitors = {} # monitor port => [worker index, its Ractor]
        @controls = {} # worker index => its control port
        @holding = {} # worker index => id of the job it's running
        @to_release = [] # ids of jobs dead workers held, not yet released
        @holding_port = Ractor::Port.new
        @worker_count.times { |index| spawn_worker(index) }
        Monk::Log.info(
          "Monk::Jobs process #{@process_id} started: #{@worker_count} workers on #{@queues.join(", ")} (pid #{@pid})",
        )

        ticker, timer = start_ticker
        supervise(ticker)
        shut_down(ticker)
      ensure
        timer&.kill
        ticker&.close
        @holding_port&.close
      end

      # Asks run to stop; safe from a signal handler or another thread.
      def stop
        @stopping = true
      end

      private

      def supervise(ticker)
        last_heartbeat = monotonic
        dead = []
        until @stopping
          port, message = Ractor.select(ticker, @holding_port, *@monitors.keys)
          if port.equal?(ticker)
            last_heartbeat = tick(last_heartbeat)
            # Respawned on the next tick rather than at once, so a worker
            # that dies straight away (the database is down) can't spin.
            dead.each { |index| spawn_worker(index) }
            dead.clear
          elsif port.equal?(@holding_port)
            index, id = message
            id ? @holding[index] = id : @holding.delete(index)
          else
            dead << worker_exited(port)
          end
        end
      end

      # A database error here (Postgres restarting, a dropped connection)
      # mustn't end the process: it's logged, this Ractor's connection is
      # reset, and the next tick tries again.
      def tick(last_heartbeat)
        release_dead_workers_jobs
        @adapter.stage_due
        return last_heartbeat if monotonic - last_heartbeat < @heartbeat_interval

        beat
        monotonic
      rescue StandardError => e
        Monk::Log.error("Monk::Jobs supervisor: #{Monk::Jobs.describe_error(e)}; reconnecting")
        reconnect
        last_heartbeat
      end

      # A job stays on the list until its release has gone through (or found
      # the job no longer held), so a database error just retries it next tick.
      def release_dead_workers_jobs
        until @to_release.empty?
          @adapter.release(@to_release.first, @process_id)
          @to_release.shift
        end
      end

      def reconnect
        @adapter.reset_connection
      rescue StandardError => e
        Monk::Log.error("Monk::Jobs supervisor: can't reconnect yet (#{e.class}: #{e.message})")
      end

      def beat
        @adapter.heartbeat(@process_id, hostname: @hostname, pid: @pid)
        released = @adapter.prune(@process_timeout)
        return unless released.positive?

        Monk::Log.warn("Monk::Jobs: released #{released} job(s) of processes silent for #{@process_timeout}s")
      end

      def spawn_worker(index)
        hello = Ractor::Port.new
        args = [@adapter, @process_id, @queues, @poll_interval, hello, @holding_port, index]
        ractor = Ractor.new(*args, name: "monk-jobs-worker-#{index}") { |*worker_args| Monk::Jobs::Worker.run(*worker_args) }
        @controls[index] = hello.receive
        monitor = Ractor::Port.new
        ractor.monitor(monitor)
        @monitors[monitor] = [index, ractor]
      ensure
        hello&.close
      end

      # One port per worker: Ractor#monitor's message is a bare :exited or
      # :aborted that doesn't say which Ractor (Phase 0.4).
      def worker_exited(port)
        index, ractor = @monitors.delete(port)
        @controls.delete(index)
        held = @holding.delete(index)
        @to_release << held if held
        begin
          ractor.value
          Monk::Log.warn("Monk::Jobs: worker #{index} exited; starting a new one")
        rescue Ractor::RemoteError => e
          Monk::Log.error("Monk::Jobs: worker #{index} died; starting a new one. #{Monk::Jobs.describe_error(e.cause)}")
        end
        index
      end

      def shut_down(ticker)
        Monk::Log.info(
          "Monk::Jobs process #{@process_id} stopping: waiting up to #{@shutdown_timeout}s for jobs in flight",
        )
        @controls.each_value do |control|
          control << :stop
        rescue Ractor::ClosedError
          nil
        end

        deadline = monotonic + @shutdown_timeout
        until @monitors.empty? || monotonic >= deadline
          port, = Ractor.select(ticker, *@monitors.keys)
          @monitors.delete(port) unless port.equal?(ticker)
        end
        unless @monitors.empty?
          Monk::Log.warn(
            "Monk::Jobs: #{@monitors.size} worker(s) still busy after #{@shutdown_timeout}s; releasing their jobs",
          )
        end

        begin
          @adapter.deregister(@process_id)
        rescue StandardError => e
          # Its jobs are released by another process's pruning instead.
          Monk::Log.error("Monk::Jobs process #{@process_id} couldn't deregister: #{e.class}: #{e.message}")
        end
        Monk::Log.info("Monk::Jobs process #{@process_id} stopped")
      end

      def start_ticker
        ticker = Ractor::Port.new
        interval = @tick_interval
        timer = Thread.new do
          loop do
            sleep interval
            ticker << :tick
          end
        rescue Ractor::ClosedError
          nil
        end
        [ticker, timer]
      end

      def trap_signals!
        %w[TERM INT].each { |signal| Signal.trap(signal) { stop } }
      end

      def checked_queues(queues)
        unless queues.is_a?(Array) && queues.any? && queues.all? { |q| q.is_a?(String) && !q.empty? }
          raise ArgumentError, "queues must be a non-empty Array of queue names, got #{queues.inspect}"
        end

        Ractor.make_shareable(queues.map(&:dup))
      end

      def positive_integer?(value)
        value.is_a?(Integer) && value.positive?
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
