# The whole framework, as monk/live does: jobs use Monk.freeze!, Monk::Log
# and Monk.env, and a job process (bin/jobs) may load nothing else first.
require_relative "../monk"
require_relative "jobs/errors"
require_relative "jobs/args"
require "json"

module Monk
  # Background jobs on Postgres. Opt-in: require "monk/jobs" explicitly --
  # `require "monk"` alone does not load this. Design:
  # docs/adr/0013-jobs-narrow-state-table-plus-payloads.md; plan:
  # docs/history/plan-jobs.md.
  module Jobs
    # last_error keeps the first lines of a failure, not all of it.
    MAX_ERROR_LENGTH = 4_000
    BACKTRACE_LINES = 10

    # The process id drain! claims jobs as: never a monk_processes id, which
    # starts at 1.
    DRAIN_PROCESS_ID = 0

    class << self
      # Typically, in config/jobs.rb:
      #
      #   Monk::Jobs.configure(db_name: :primary)
      #
      # db_name: is a database registered with Monk::Persistence::Pg. The
      # app's own database by default, so a job can be enqueued inside the
      # app's own transaction; a separate one isolates the queue from the
      # app's long transactions (docs/adr/0013-jobs-narrow-state-table-plus-payloads.md).
      # Tests use the app's test database, the same way: enqueue, drain!,
      # and clear! between tests.
      def configure(db_name:)
        require_relative "jobs/adapters/pg"
        @adapter = Adapters::Pg.new(db_name: db_name)
      end

      # The configured adapter. Shareable (it freezes itself), so a worker
      # Ractor reads it straight off this module.
      def adapter
        @adapter || raise(NotConfiguredError, "call Monk::Jobs.configure(db_name:) before enqueueing or running jobs")
      end

      # Stores a job to run later; returns its id. args are passed to the
      # job's self.perform as they are, and must be plain JSON values
      # (Args.check!). Options:
      #
      #   wait: 60                  run no sooner than 60 seconds from now
      #   at: Time                  run no sooner than then
      #   conn: a PG::Connection    enqueue on it, inside its transaction, so
      #                             the job commits or rolls back with the
      #                             app's own writes
      #
      # SendReceipt.enqueue(order_id) is the same call.
      def enqueue(job_class, *args, wait: nil, at: nil, conn: nil)
        check_enqueueable!(job_class)
        Args.check!(args)
        check_schedule!(wait, at)

        adapter.enqueue(
          job_class: job_class.name, queue: job_class.queue, priority: job_class.priority,
          max_attempts: job_class.max_attempts, args: JSON.generate(args), wait: wait, at: at, conn: conn,
        )
      end

      # Called by Monk::Job.inherited, in the main Ractor as the app's job
      # files load. Only recorded here: names are resolved when the
      # registry is frozen, so a class that gets its constant name after
      # being created (Foo = Class.new(Monk::Job)) is still found.
      def record(job_class)
        classes << job_class
      end

      # The Monk::Job subclass a monk_job_payloads.job_class names. Only
      # ever answers with a recorded job class -- never Object.const_get
      # on a String read from the database. Reads nothing but the frozen
      # registry, so it works the same from any Ractor.
      def lookup(name)
        registry = @registry
        if registry.nil?
          raise NotFrozenError,
            "Monk::Jobs.lookup(#{name.inspect}) before the job registry is frozen -- call Monk.boot(app) " \
            "(or Monk.freeze!) in the main Ractor first, after the app's job classes are loaded"
        end

        registry.fetch(name) do
          raise UnknownJobError, "no Monk::Job subclass named #{name.inspect} is loaded in this process"
        end
      end

      # Called from Monk.freeze! via Monk.freeze_hooks. Rebuilds the map
      # from every named job class recorded so far, so freezing twice (two
      # apps, or a test suite) is harmless. Anonymous classes are skipped:
      # without a name a job can never be found again once enqueued.
      def freeze_registry!
        @registry = Ractor.make_shareable(classes.filter_map { |job| [job.name, job] if job.name }.to_h)
      end

      # A failed job back to available, with its attempts reset; true if it
      # was failed. Failed jobs stay in monk_jobs until retried or discarded.
      def retry_failed(id)
        adapter.retry_failed(id)
      end

      # Deletes a failed job; true if it was failed.
      def discard_failed(id)
        adapter.discard_failed(id)
      end

      # Seconds to wait before retrying a job that has failed `attempts`
      # times: 16, 31, 96, 271, 640, ... (Sidekiq's curve, without its
      # random jitter).
      def backoff(attempts)
        (attempts**4) + 15
      end

      # What goes in last_error: the class and message, then the first
      # BACKTRACE_LINES of the backtrace, capped at MAX_ERROR_LENGTH.
      def describe_error(error)
        lines = ["#{error.class}: #{error.message}", *Array(error.backtrace).first(BACKTRACE_LINES)]
        lines.join("\n")[0, MAX_ERROR_LENGTH]
      end

      # Runs every job that's due, one after another, until none is left --
      # including jobs those jobs enqueue -- and returns how many ran. For
      # an app's tests: enqueue, drain!, then assert on what the jobs did.
      # Nothing is retried: the first job that raises is marked failed and
      # its error re-raised here.
      #
      # Each job runs in a throwaway Ractor, as it would in bin/jobs, so a
      # job that only works in the main Ractor (a gem with module-level
      # state, a non-shareable constant) fails in the test too.
      # in_ractor: false runs jobs in the calling Ractor instead, for a test
      # that needs to see a job's side effects there.
      #
      # Calls Monk.freeze! first, as bin/jobs does, so jobs can read the
      # app's frozen configuration from their Ractor.
      def drain!(in_ractor: true)
        Monk.freeze!
        queues = classes.map(&:queue) | [Job::DEFAULT_QUEUE]
        ran = 0
        loop do
          nil while adapter.stage_due.positive?
          claim = queues.lazy.filter_map { |queue| adapter.claim(queue, DRAIN_PROCESS_ID) }.first
          break unless claim

          run_drained(claim, in_ractor)
          ran += 1
        end
        ran
      end

      # Empties the queue: every job, failed ones included, and every job
      # process row. For an app's tests, between one test and the next --
      # and so it refuses to run unless MONK_ENV is test.
      def clear!
        unless Monk.env.test?
          raise ClearOutsideTestsError,
            "Monk::Jobs.clear! empties the whole queue, so it only runs with MONK_ENV=test (this is #{Monk.env})"
        end

        adapter.clear!
      end

      # Test-only: unfreezes the registry and forgets the configuration.
      # Recorded classes stay recorded, the same way a Ruby class can't be
      # undefined.
      def reset!
        @registry = nil
        @adapter = nil
      end

      private

      def run_drained(claim, in_ractor)
        begin
          job = lookup(claim.job_class)
          in_ractor ? perform_in_ractor(job, claim.args) : job.perform(*claim.args)
        # NotImplementedError too, a job class with no self.perform: it's a
        # ScriptError, not a StandardError, and would otherwise leave the job
        # running.
        rescue StandardError, NotImplementedError => e
          adapter.fail(claim.id, DRAIN_PROCESS_ID, error: describe_error(e), retry_in: nil)
          raise
        end
        adapter.finish(claim.id, DRAIN_PROCESS_ID)
      end

      def perform_in_ractor(job, args)
        Ractor.new(job, args) do |job, args|
          # The error is re-raised in the caller; don't also print it here.
          Thread.current.report_on_exception = false
          job.perform(*args)
          nil
        end.value
      rescue Ractor::RemoteError => e
        # The job's own error, as if it had run here. cause: nil, or Ruby
        # would chain the RemoteError onto it -- whose cause it already is.
        raise e.cause, cause: nil
      end

      def check_enqueueable!(job_class)
        unless job_class.is_a?(Class) && job_class < Monk::Job
          raise ArgumentError, "Monk::Jobs.enqueue needs a Monk::Job subclass, got #{job_class.inspect}"
        end
        return if job_class.name

        raise ArgumentError,
          "#{job_class.inspect} has no name, so a worker could never find it again -- assign it to a constant"
      end

      def check_schedule!(wait, at)
        raise ArgumentError, "pass wait: or at:, not both" if wait && at
        if wait && !(wait.is_a?(Numeric) && wait >= 0)
          raise ArgumentError, "wait: must be a number of seconds, zero or more, got #{wait.inspect}"
        end
        raise ArgumentError, "at: must be a Time, got #{at.inspect}" if at && !at.is_a?(Time)
      end

      def classes
        @classes ||= []
      end
    end

    Monk.freeze_hooks << self
  end
end

require_relative "jobs/job"
