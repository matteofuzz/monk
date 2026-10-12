require "json"
require_relative "../log"

module Monk
  module Jobs
    # The supervisor's per-tick step for recurring tasks
    # (docs/plan-scheduled-jobs.md decisions 5-7): asks the database about
    # each task's most recent occurrence, which enqueues it at most once
    # across every job process. Lives in the supervisor and isn't shared:
    # the occurrence each task last handled is this process's own memory,
    # so a tick reaches the database once per occurrence, not once a second.
    class Scheduler
      # Past this many, a catch-up log line stops counting.
      MAX_SKIPPED_COUNT = 10_000

      def initialize(adapter, tasks)
        @adapter = adapter
        @tasks = tasks
        @handled = {} # task key => the occurrence last handled here
      end

      # One pass as if the clock read `now`. clock: replaces the database
      # clock too (Monk::Jobs.run_scheduler!); without it, the database
      # decides whether an occurrence has arrived. Returns each task asked
      # about this pass, key => Firing#result.
      def run(now = Time.now, clock: nil)
        @tasks.each_with_object({}) do |task, results|
          occurrence = task.cron.previous(now)
          next if @handled[task.key] == occurrence

          firing = fire(task, occurrence, clock)
          @handled[task.key] = occurrence unless firing.result == :not_due
          report(task, occurrence, firing)
          results[task.key] = firing.result
        end
      end

      private

      def fire(task, occurrence, clock)
        job = task.job_class
        @adapter.fire_recurring(
          key: task.key, cron: task.cron.expression, occurrence: occurrence, skip_if_pending: task.skip_if_pending,
          job_class: job.name, queue: job.queue, priority: job.priority, max_attempts: job.max_attempts,
          args: JSON.generate(task.args), clock: clock,
        )
      end

      def report(task, occurrence, firing)
        prefix = "Monk::Jobs recurring #{task.key}:"
        case firing.result
        when :initialized
          Monk::Log.info("#{prefix} new task, first run at #{stamp(task.cron.next_after(occurrence))}")
        when :reinitialized
          Monk::Log.info("#{prefix} cron changed to #{task.cron.expression.inspect}, " \
                         "first run at #{stamp(task.cron.next_after(occurrence))}")
        when :enqueued
          Monk::Log.info("#{prefix} enqueued job #{firing.job_id} for #{stamp(occurrence)}")
        when :skipped_pending
          Monk::Log.info("#{prefix} skipped #{stamp(occurrence)}, the previous run is still pending")
        end
        report_catch_up(task, occurrence, firing, prefix)
      end

      # Decision 6: after downtime only the latest occurrence fires.
      def report_catch_up(task, occurrence, firing, prefix)
        return unless %i[enqueued skipped_pending].include?(firing.result) && firing.previous_checkpoint

        skipped = skipped_between(task.cron, firing.previous_checkpoint, occurrence)
        return if skipped.zero?

        count = skipped >= MAX_SKIPPED_COUNT ? "#{MAX_SKIPPED_COUNT}+" : skipped
        Monk::Log.warn(
          "#{prefix} caught up from #{stamp(firing.previous_checkpoint)}, skipped #{count} occurrences",
        )
      end

      def skipped_between(cron, from, to)
        count = 0
        time = cron.next_after(from)
        while time < to && count < MAX_SKIPPED_COUNT
          count += 1
          time = cron.next_after(time)
        end
        count
      end

      def stamp(time) = time.utc.iso8601
    end
  end
end
