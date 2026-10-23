module Monk
  module Jobs
    # One declared schedule (Monk::Jobs.recurring): the key it's stored
    # under in monk_recurring_tasks, the job class to enqueue, its parsed
    # Cron and the args to enqueue with. Queue, priority and max_attempts
    # come from the job class, as with any enqueue.
    RecurringTask = Data.define(:key, :job_class, :cron, :args, :skip_if_pending)
  end
end
