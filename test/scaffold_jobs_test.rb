require_relative "test_helper"
require "rbconfig"
require "tmpdir"
require "monk/scaffold"
require "monk/jobs"
require "monk/persistence/pg"
require "monk/persistence/pg/migrator"

# monk new --jobs (docs/history/plan-jobs.md Phase 8, Seam E): the files it
# writes, how it wires them in, and -- since a scaffold that doesn't run is
# worse than none -- the generated config and bin/jobs actually working
# against a real database.
class ScaffoldJobsTest < Minitest::Test
  include PersistenceTestHelpers
  include JobsTestHelpers

  def test_jobs_implies_postgres
    in_scaffold(jobs: true) do |dest|
      assert File.exist?(File.join(dest, "config/persistence.rb"))
      assert_includes read(dest, "Gemfile"), template("postgres/Gemfile.extra")
    end
  end

  def test_jobs_writes_its_config_demo_job_script_and_migration
    in_scaffold(jobs: true) do |dest|
      assert_equal template("jobs/config/jobs.rb"), read(dest, "config/jobs.rb")
      assert_equal template("jobs/jobs/hello_job.rb"), read(dest, "jobs/hello_job.rb")
      assert_equal template("jobs/bin/jobs"), read(dest, "bin/jobs")
      %w[up down].each do |direction|
        migration = "db/migrate/00000000000002_create_jobs_tables.#{direction}.sql"
        assert_equal template("jobs/#{migration}"), read(dest, migration)
      end
    end
  end

  def test_bin_jobs_is_executable
    in_scaffold(jobs: true) do |dest|
      mode = File.stat(File.join(dest, "bin/jobs")).mode
      assert mode & 0o111 == 0o111, "expected bin/jobs to be executable"
    end
  end

  def test_without_jobs_nothing_of_it_is_written
    in_scaffold(postgres: true) do |dest|
      refute File.exist?(File.join(dest, "config/jobs.rb"))
      refute File.exist?(File.join(dest, "bin/jobs"))
      refute_includes read(dest, "config.ru"), "config/jobs"
      refute_includes read(dest, ".env"), "JOBS_"
    end
  end

  def test_config_ru_requires_jobs_after_persistence_and_adds_the_demo_route
    in_scaffold(jobs: true) do |dest|
      config_ru = read(dest, "config.ru")

      assert_includes config_ru, %(require_relative "config/persistence"\nrequire_relative "config/jobs"\n)
      assert_includes config_ru, %(post("/jobs/hello"))
    end
  end

  def test_config_ru_requires_jobs_after_auth_and_mail
    in_scaffold(jobs: true, auth: true) do |dest|
      assert_includes read(dest, "config.ru"),
        %(require_relative "config/auth"\nrequire_relative "config/mail"\nrequire_relative "config/jobs"\n)
    end
  end

  def test_the_live_config_ru_gets_the_demo_route_too
    in_scaffold(jobs: true, live: true) do |dest|
      config_ru = read(dest, "config.ru")

      assert_includes config_ru, %(post("/jobs/hello"))
      assert_includes config_ru, %(require_relative "config/jobs")
    end
  end

  # Tests run jobs with Monk::Jobs.drain!, so .env.test has no need of them.
  def test_env_files_get_the_job_process_settings_but_not_env_test
    in_scaffold(jobs: true) do |dest|
      %w[.env .env.example].each do |file|
        assert_includes read(dest, file), "JOBS_WORKERS="
        assert_includes read(dest, file), "JOBS_QUEUES=default"
      end
      refute_includes read(dest, ".env.test"), "JOBS_"
    end
  end

  def test_setup_md_covers_running_and_testing_jobs
    in_scaffold(jobs: true) do |dest|
      setup = read(dest, "SETUP.md")

      assert_includes setup, "bin/jobs"
      assert_includes setup, "/jobs/hello"
      assert_includes setup, %(require_relative "../config/jobs")
      assert_includes setup, "Monk::Jobs.drain!"
      assert_includes setup, "Monk::Jobs.clear!"
    end
  end

  def test_setup_md_without_jobs_doesnt_mention_them
    in_scaffold(postgres: true) do |dest|
      refute_includes read(dest, "SETUP.md"), "bin/jobs"
    end
  end

  # The generated pieces together, as the app's own tests would use them:
  # config/jobs.rb (with config/persistence.rb under it) loaded, the
  # generated migration applied, the demo job enqueued and drained.
  def test_the_generated_config_enqueues_and_drains_the_demo_job
    skip_unless_postgres_available

    in_scaffold(jobs: true) do |dest|
      with_generated_app(dest) do
        HelloJob.enqueue("Ann")

        assert_equal 1, Monk::Jobs.drain!
        assert_includes File.read(File.join(@log_dir, "test.log")), "Hello, Ann, from a background job"
      end
    end
  end

  # bin/jobs as a real process, the way a developer runs it: it registers,
  # runs the demo job, and stops cleanly on TERM.
  def test_the_generated_bin_jobs_runs_jobs_and_stops_on_term
    skip_unless_postgres_available

    in_scaffold(jobs: true) do |dest|
      with_generated_app(dest) do
        HelloJob.enqueue("Bob")
        pid = Process.spawn(generated_app_env, RbConfig.ruby, "-W0", "bin/jobs", chdir: dest, out: File::NULL)

        begin
          wait_until { count_rows(:primary, "monk_jobs").zero? }
          assert_equal 1, count_rows(:primary, "monk_processes")
        ensure
          Process.kill("TERM", pid)
          _, status = Process.wait2(pid)
        end

        assert_predicate status, :success?
        assert_equal 0, count_rows(:primary, "monk_processes")
        assert_includes File.read(File.join(dest, "log/test.log")), "Hello, Bob, from a background job"
      end
    end
  end

  private

  def in_scaffold(**flags)
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest, **flags).write!
      yield dest
    end
  end

  # Loads the generated config against the test database, with the
  # generated migration applied, and cleans both up afterwards.
  def with_generated_app(dest)
    with_log do |log_dir|
      @log_dir = log_dir
      with_settings do
        with_env_vars(generated_app_env) do
          Monk::Persistence::Pg.reset! if defined?(Monk::Persistence::Pg)
          Monk::Jobs.reset! if defined?(Monk::Jobs)
          require File.join(dest, "config/settings")
          load File.join(dest, "config/persistence.rb")
          Monk::Persistence::Pg.checkout(:primary) { |conn| drop_jobs_tables(conn) }
          load File.join(dest, "config/jobs.rb")
          Monk::Persistence::Pg::Migrator.new(db_name: :primary, dir: File.join(dest, "db/migrate")).migrate!
          yield
        ensure
          Monk::Persistence::Pg.checkout(:primary) { |conn| drop_jobs_tables(conn) }
        end
      end
    end
  ensure
    Monk::Jobs.reset! if defined?(Monk::Jobs)
    Monk::Persistence::Pg.reset! if defined?(Monk::Persistence::Pg)
    Monk::Views.reset!
  end

  # What the generated config/persistence.rb reads, pointed at the test
  # database; BUNDLE_GEMFILE so the generated bin/jobs's bundler/setup
  # resolves monk's own bundle rather than the uninstalled app's.
  def generated_app_env
    opts = pg_test_opts
    {
      "DB_HOST" => opts[:host], "DB_PORT" => opts[:port].to_s, "DB_USER" => opts[:user],
      "DB_PASSWORD" => opts[:password], "DB_NAME" => opts[:dbname],
      "MONK_ENV" => "test", "JOBS_WORKERS" => "1",
      "BUNDLE_GEMFILE" => File.expand_path("../Gemfile", __dir__),
    }
  end

  def with_env_vars(vars, &)
    return yield if vars.empty?

    name, value = vars.first
    with_env(name, value) { with_env_vars(vars.drop(1).to_h, &) }
  end

  def wait_until(timeout: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk("condition not met within #{timeout}s") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  def template(relative)
    File.read(File.expand_path("../lib/monk/templates/#{relative}", __dir__))
  end

  def read(dest, relative)
    File.read(File.join(dest, relative))
  end
end
