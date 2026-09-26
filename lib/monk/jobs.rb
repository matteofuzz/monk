require_relative "freeze_hooks"
require_relative "jobs/errors"
require_relative "jobs/args"
require "json"

module Monk
  # Background jobs on Postgres. Opt-in: require "monk/jobs" explicitly --
  # `require "monk"` alone does not load this. Design:
  # docs/adr/0013-jobs-narrow-state-table-plus-payloads.md; plan:
  # docs/history/plan-jobs.md.
  module Jobs
    class << self
      # Typically, in config/jobs.rb:
      #
      #   Monk::Jobs.configure(db_name: :primary)
      #
      # db_name: is a database registered with Monk::Persistence::Pg. The
      # app's own database by default, so a job can be enqueued inside the
      # app's own transaction; a separate one isolates the queue from the
      # app's long transactions (docs/adr/0013-jobs-narrow-state-table-plus-payloads.md).
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

      # Test-only: unfreezes the registry and forgets the configuration.
      # Recorded classes stay recorded, the same way a Ruby class can't be
      # undefined.
      def reset!
        @registry = nil
        @adapter = nil
      end

      private

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
