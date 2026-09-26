module Monk
  module Jobs
    # Looking up a job class before Monk.freeze! (Monk.boot calls it) has
    # sealed the registry -- from a worker Ractor the unfrozen registry
    # couldn't even be read.
    class NotFrozenError < StandardError
    end

    # A job_class name that isn't a Monk::Job subclass this process knows
    # about: a job enqueued by a newer deploy, a renamed class, or a name
    # that was never a job at all.
    class UnknownJobError < StandardError
    end

    # An ArgumentError, like Monk::Mail::InvalidMessageError: it's always
    # the caller's input that's wrong.
    class InvalidArgumentsError < ArgumentError
    end
  end
end
