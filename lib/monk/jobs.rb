require_relative "freeze_hooks"
require_relative "jobs/errors"
require_relative "jobs/args"

module Monk
  # Background jobs on Postgres. Opt-in: require "monk/jobs" explicitly --
  # `require "monk"` alone does not load this. Design:
  # docs/adr/0013-jobs-narrow-state-table-plus-payloads.md; plan:
  # docs/history/plan-jobs.md.
  module Jobs
    class << self
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

      # Test-only: unfreezes the registry. Recorded classes stay recorded,
      # the same way a Ruby class can't be undefined.
      def reset!
        @registry = nil
      end

      private

      def classes
        @classes ||= []
      end
    end

    Monk.freeze_hooks << self
  end
end

require_relative "jobs/job"
