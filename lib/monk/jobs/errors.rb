module Monk
  module Jobs
    # Looking up a job class before Monk.freeze! (Monk.boot calls it) has
    # sealed the registry -- from a worker Ractor the unfrozen registry
    # couldn't even be read.
    class NotFrozenError < StandardError
    end

    # Declaring a recurring task after Monk.freeze! has sealed the
    # registry: it would never be seen by the scheduler.
    class RegistryFrozenError < StandardError
    end

    # bin/jobs starting with recurring tasks declared but no
    # monk_recurring_tasks table: an app that has jobs from before 0.22
    # and hasn't added the migration yet.
    class MissingRecurringTableError < StandardError
    end

    # A job_class name that isn't a Monk::Job subclass this process knows
    # about: a job enqueued by a newer deploy, a renamed class, or a name
    # that was never a job at all.
    class UnknownJobError < StandardError
    end

    # Enqueueing (or claiming) before Monk::Jobs.configure has picked the
    # database the queue lives in.
    class NotConfiguredError < StandardError
    end

    # Monk::Jobs.clear! outside MONK_ENV=test: it would empty a real queue.
    class ClearOutsideTestsError < StandardError
    end

    # Monk::Jobs.run_scheduler! outside MONK_ENV=test: it would fire a real
    # app's schedules at a made-up time.
    class RunSchedulerOutsideTestsError < StandardError
    end

    # An ArgumentError, like Monk::Mail::InvalidMessageError: it's always
    # the caller's input that's wrong.
    class InvalidArgumentsError < ArgumentError
    end

    # A recurring task's cron expression that doesn't parse, or never
    # matches a minute. Raised when the task is declared, at boot.
    class InvalidCronError < ArgumentError
    end
  end
end
