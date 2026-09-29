# Job classes shared by test/jobs_process_test.rb (which enqueues) and
# test/support/jobs_process.rb (the child job process that runs them).
# They record into jobs_process_results, which the test reads.
module JobsProcessJobs
  DB = :jobs_process_test_db
  # Every connection a child job process opens carries this, so a test can
  # kill that process's connections and nobody else's.
  APPLICATION_NAME = "monk_jobs_process_test".freeze

  def self.record(value)
    Monk::Persistence::Pg.checkout(DB) do |conn|
      conn.exec_params("INSERT INTO jobs_process_results (value) VALUES ($1)", [value])
    end
  end

  class Record < Monk::Job
    def self.perform(value) = JobsProcessJobs.record(value)
  end

  # Records when it starts and when it ends, so a test can kill the
  # process in between.
  class Long < Monk::Job
    def self.perform(seconds, value)
      JobsProcessJobs.record("#{value} started")
      sleep seconds
      JobsProcessJobs.record("#{value} finished")
    end
  end
end
