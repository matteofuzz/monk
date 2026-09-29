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
  include AuthTestHelpers

  def test_jobs_implies_postgres
    in_scaffold(jobs: true) do |dest|
      assert File.exist?(File.join(dest, "config/persistence.rb"))
      assert_includes read(dest, "Gemfile"), template("postgres/Gemfile.extra")
    end
  end

  def test_jobs_writes_its_config_demo_job_script_and_migration
    in_scaffold(jobs: true) do |dest|
      assert_equal template("jobs/config/jobs.rb"), read(dest, "config/jobs.rb")
      assert_equal template("jobs/app/jobs/hello_job.rb"), read(dest, "app/jobs/hello_job.rb")
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
      refute_includes read(dest, "config/load.rb"), %(require_relative "jobs")
      refute_includes read(dest, "app/app.rb"), "/jobs/hello"
      refute_includes read(dest, ".env"), "JOBS_"
    end
  end

  def test_config_load_requires_jobs_after_persistence_and_the_app_gets_the_demo_route
    in_scaffold(jobs: true) do |dest|
      assert_includes read(dest, "config/load.rb"), %(require_relative "persistence"\nrequire_relative "jobs"\n)
      assert_includes read(dest, "app/app.rb"), %(post("/jobs/hello"))
    end
  end

  def test_config_load_requires_jobs_after_auth_and_mail
    in_scaffold(jobs: true, auth: true) do |dest|
      assert_includes read(dest, "config/load.rb"),
        %(require_relative "auth"\nrequire_relative "mail"\nrequire_relative "jobs"\n)
    end
  end

  def test_the_live_app_gets_the_demo_route_too
    in_scaffold(jobs: true, live: true) do |dest|
      assert_includes read(dest, "app/app.rb"), %(post("/jobs/hello"))
      assert_includes read(dest, "config/load.rb"), %(require_relative "jobs")
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

  # --- with --auth and --mail (docs/adr/0014) ---

  def test_auth_and_jobs_write_the_send_login_link_job
    in_scaffold(jobs: true, auth: true) do |dest|
      assert_equal template("jobs/app/jobs/send_login_link.rb"), read(dest, "app/jobs/send_login_link.rb")
    end
  end

  def test_jobs_without_auth_write_no_send_login_link_job
    in_scaffold(jobs: true, mail: true) do |dest|
      refute File.exist?(File.join(dest, "app/jobs/send_login_link.rb"))
    end
  end

  def test_mail_and_jobs_load_deliver_later_and_serve_mailers_first
    in_scaffold(jobs: true, mail: true) do |dest|
      assert_includes read(dest, "config/jobs.rb"), %(require "monk/jobs"\nrequire "monk/mail/later"\n)
      assert_includes read(dest, ".env"), "JOBS_QUEUES=mailers,default"
      assert_includes read(dest, ".env.example"), "JOBS_QUEUES=mailers,default"
      assert_includes read(dest, "SETUP.md"), "Monk::Mail.deliver_later"
    end
  end

  def test_jobs_without_mail_neither_load_deliver_later_nor_add_a_mailers_queue
    in_scaffold(jobs: true) do |dest|
      refute_includes read(dest, "config/jobs.rb"), "monk/mail/later"
      assert_includes read(dest, ".env"), "JOBS_QUEUES=default\n"
    end
  end

  def test_setup_md_shows_the_login_route_enqueueing_send_login_link
    in_scaffold(jobs: true, auth: true) do |dest|
      assert_includes read(dest, "SETUP.md"), "SendLoginLink.enqueue(params[:email])"
    end
  end

  # ADR 0014's whole point: the job carries only the email, the token is
  # created and sent inside the job, and the link it sends works.
  def test_the_generated_send_login_link_sends_a_working_link_without_ever_storing_the_token
    skip_unless_postgres_available

    in_scaffold(jobs: true, auth: true) do |dest|
      with_generated_auth_app(dest) do
        SendLoginLink.enqueue("ann@example.test")
        assert_equal ["ann@example.test"], JSON.parse(queued_args), "only the email is queued"
        assert_equal 0, count_rows(:primary, "login_tokens"), "no token exists until the job runs"

        assert_equal 1, Monk::Jobs.drain!

        link = File.read(File.join(@log_dir, "test.log"))[%r{http://localhost:9292/auth/callback/[\w-]+}]
        refute_nil link, "the email carries the link"
        assert_equal "ann@example.test", Monk::Auth.redeem(link.split("/").last)&.fetch(:subject)
      end
    end
  end

  # The generated pieces together, as the app's own tests would use them:
  # config/load.rb loaded (config/jobs.rb, then app/jobs/), the generated
  # migration applied, the demo job enqueued and drained.
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

  # With --live, bin/jobs's config/load.rb also loads config/live.rb, so a
  # job can push a Live update. It only publishes, so it never calls
  # listen!: no LISTEN connection, only the jobs' own.
  def test_the_generated_bin_jobs_of_a_live_app_runs_jobs_and_stops_on_term
    skip_unless_postgres_available

    in_scaffold(jobs: true, live: true, postgres: true) do |dest|
      with_generated_app(dest) do
        HelloJob.enqueue("Cleo")
        listeners_before = live_listener_count
        pid = Process.spawn(generated_app_env, RbConfig.ruby, "-W0", "bin/jobs", chdir: dest, out: File::NULL)

        begin
          wait_until { count_rows(:primary, "monk_jobs").zero? }
          assert_equal listeners_before, live_listener_count, "bin/jobs mustn't LISTEN"
        ensure
          Process.kill("TERM", pid)
          _, status = Process.wait2(pid)
        end

        assert_predicate status, :success?
        assert_includes File.read(File.join(dest, "log/test.log")), "Hello, Cleo, from a background job"
      end
    end
  ensure
    Monk::Live.reset! if defined?(Monk::Live)
  end

  private

  # Backends whose last statement was PgFanout's LISTEN (as in
  # test/websocket_pg_fanout_test.rb).
  def live_listener_count
    Monk::Persistence::Pg.checkout(:primary) do |conn|
      conn.exec_params(
        "SELECT count(*) FROM pg_stat_activity WHERE query = $1 AND datname = current_database()",
        ["LISTEN #{Monk::WebSocket::PgFanout::CHANNEL}"],
      ).getvalue(0, 0).to_i
    end
  end

  def in_scaffold(**flags)
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest, **flags).write!
      yield dest
    end
  end

  # Loads the generated app's config/load.rb against the test database --
  # the configs, then app/ -- with the generated migration applied, and
  # cleans both up afterwards.
  def with_generated_app(dest)
    with_log do |log_dir|
      @log_dir = log_dir
      with_settings do
        with_env_vars(generated_app_env) do
          Monk::Persistence::Pg.reset! if defined?(Monk::Persistence::Pg)
          Monk::Jobs.reset! if defined?(Monk::Jobs)
          require File.join(dest, "config/load")
          Monk::Persistence::Pg.checkout(:primary) { |conn| drop_jobs_tables(conn) }
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

  # The same, for an --auth --jobs app (mail on log://), with both
  # generated migrations applied.
  def with_generated_auth_app(dest)
    with_log do |log_dir|
      @log_dir = log_dir
      with_settings do
        with_env_vars(generated_app_env.merge("AUTH_SECRET" => "s3cr3t", "MAIL_URL" => "log://")) do
          Monk::Persistence::Pg.reset! if defined?(Monk::Persistence::Pg)
          Monk::Jobs.reset! if defined?(Monk::Jobs)
          require File.join(dest, "config/load")
          Monk::Persistence::Pg.checkout(:primary) do |conn|
            drop_jobs_tables(conn)
            drop_auth_tables(conn)
          end
          Monk::Views.reset!
          Monk::Views.root = File.join(dest, "app/views") # as the generated bin/jobs does
          Monk::Persistence::Pg::Migrator.new(db_name: :primary, dir: File.join(dest, "db/migrate")).migrate!
          yield
        ensure
          Monk::Persistence::Pg.checkout(:primary) do |conn|
            drop_jobs_tables(conn)
            drop_auth_tables(conn)
          end
        end
      end
    end
  ensure
    Monk::Jobs.reset! if defined?(Monk::Jobs)
    Monk::Auth.reset! if defined?(Monk::Auth)
    Monk::Mail.reset! if defined?(Monk::Mail)
    Monk::Persistence::Pg.reset! if defined?(Monk::Persistence::Pg)
    Monk::Views.reset!
  end

  def queued_args
    Monk::Persistence::Pg.checkout(:primary) do |conn|
      conn.exec("SELECT args::text FROM monk_job_payloads").getvalue(0, 0)
    end
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
