# The demo job: POST /jobs/hello enqueues it, bin/jobs runs it, and its
# line lands in log/<env>.log. A job's args must be plain JSON values (an
# id, not a record), and a job may run more than once, so make it safe to
# repeat. Replace this with the app's own jobs.
class HelloJob < Monk::Job
  def self.perform(name)
    Monk::Log.info("Hello, #{name}, from a background job")
  end
end
