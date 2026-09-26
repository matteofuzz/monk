module Monk
  module Jobs
    # A job a worker has claimed: what it needs to run it (job_class, args)
    # and to decide what happens if it raises (attempts, counting this one).
    Claim = Data.define(:id, :job_class, :args, :attempts)
  end
end
