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

  # bin/jobs as a real process, the way a developer runs it: it registers,
  # runs a job, and stops cleanly on TERM.
  def test_bin_jobs_runs_jobs_and_stops_on_term
    with_running_jobs(:jobs) do |dest, env|
      assert_includes generated(dest, "log/test.log"), "Hello, Ann, from a background job"
      assert_equal 1, count(env, "monk_processes")
    end
  end

  # In a live app bin/jobs loads config/live.rb, so a job can push an
  # update. It only publishes: it never LISTENs.
  def test_bin_jobs_of_a_live_app_never_listens
    with_running_jobs(:jobs, :live, options: { transport: "postgres" }) do |_dest, env|
      assert_equal 0, count(env, "pg_stat_activity", "query LIKE 'LISTEN %' AND datname = current_database()")
    end
  end

  private

  def with_running_jobs(*modules, options: {})
    with_new_app(*modules, options: options) do |dest|
      with_generated_database do |env|
        env = env.merge("MONK_ENV" => "test")
        out, status = run_generated_script(dest, "bin/setup_db", env)
        assert status.success?, out
        out, status = Open3.capture2e(env.merge("BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__)),
          RbConfig.ruby, "-W0", "-rbundler/setup", "-e", %(require "./config/load"; HelloJob.enqueue("Ann")),
          chdir: dest,)
        assert status.success?, out

        pid = Process.spawn(env.merge("BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__)),
          RbConfig.ruby, "-W0", "bin/jobs", chdir: dest, out: File::NULL, err: File::NULL,)
        begin
          wait_until { count(env, "monk_jobs").zero? && count(env, "monk_processes") == 1 }
          yield dest, env
        ensure
          Process.kill("TERM", pid)
          _, status = Process.wait2(pid)
        end
        assert_predicate status, :success?
        assert_equal 0, count(env, "monk_processes"), "it unregisters on the way out"
      end
    end
  end

  def count(env, table, where = "true")
    conn = PG.connect(host: env["DB_HOST"], port: env["DB_PORT"], user: env["DB_USER"], password: env["DB_PASSWORD"],
      dbname: env["DB_NAME"],)
    conn.exec("SELECT count(*) FROM #{table} WHERE #{where}").getvalue(0, 0).to_i
  ensure
    conn&.close
  end

  def wait_until(timeout: 15)
    deadline = Time.now + timeout
    sleep 0.1 until yield || Time.now > deadline
    assert yield, "timed out"
  end
end
