require_relative "test_helper"

# A job enqueued in the app's database runs: Monk::Jobs.drain! runs every
# enqueued job right here, each in its own Ractor as bin/jobs would, so a
# job that only works outside one fails here too. SETUP.md, jobs.
class JobsTest < Minitest::Test
  def teardown
    Monk::Jobs.clear!
  end

  def test_the_demo_job_runs
    HelloJob.enqueue("test")

    assert_equal 1, Monk::Jobs.drain!
  end
end
