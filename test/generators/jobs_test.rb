require_relative "../test_helper"
require "pg"

# monk add jobs (docs/plan-scaffold.md, "jobs"): needs postgres.
class GeneratorsJobsTest < Minitest::Test
  include GeneratorTestHelpers
  include PersistenceTestHelpers

  def test_writes_the_job_process_the_queue_migration_and_settings
    with_new_app(:jobs) do |dest|
      assert File.executable?(File.join(dest, "bin/jobs"))
      assert_equal template("jobs/config/jobs.rb"), generated(dest, "config/jobs.rb")
      assert_equal 2, Dir.children(File.join(dest, "db/migrate")).grep(/_create_jobs_tables\./).size
      assert_includes generated(dest, ".env"), "JOBS_QUEUES=mailers,default\n"
      refute_includes generated(dest, ".env.test"), "JOBS_", "tests run jobs with drain!, never bin/jobs"
    end
  end

  def test_says_to_run_bin_jobs
    with_new_app do |dest|
      result = add_modules(dest, :jobs)

      assert_equal ["bundle install", "start Postgres and create the databases (SETUP.md › postgres)",
                    "bin/setup_db", "bin/jobs", "bundle exec rake test",],
        result.next_steps.map { |step| step[:run] || step[:do] }, "in the order they're done"
      assert_includes result.to_text, "  3. bin/setup_db && bundle exec rake test\n  " \
                                      "… also: bin/jobs   beside bin/server (SETUP.md › jobs)\n"
    end
  end

  # With jobs installed, auth's example says to send links from a job
  # (docs/plan-scaffold.md decision 9): text only, the same files either way.
  def test_auth_after_jobs_points_at_send_login_link
    with_new_app(:jobs) do |dest|
      todo = add_modules(dest, :auth).examples.find { |entry| entry[:tag] == "auth-routes" }[:todo]

      assert_includes todo, "Monk::Auth::SendLoginLink"
    end
  end

  def test_the_apps_own_tests_pass_with_mail_and_auth_too
    with_new_app(:jobs, :auth) do |dest|
      with_generated_database do |env|
        out, status = run_generated_script(dest, "bin/setup_db", env)
        assert status.success?, out

        assert_generated_tests_pass(dest, env)
      end
    end
  end
end
