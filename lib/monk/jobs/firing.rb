module Monk
  module Jobs
    # What one fire_recurring call did for a recurring task's occurrence
    # (docs/plan-scheduled-jobs.md decision 5): result is :initialized,
    # :enqueued, :skipped_pending, :already_handled, :not_due or
    # :reinitialized; job_id is the enqueued job's, when there is one;
    # previous_checkpoint is the task's checkpoint before the call (nil
    # for a new task), for the "skipped N occurrences" log line.
    Firing = Data.define(:result, :job_id, :previous_checkpoint)
  end
end
