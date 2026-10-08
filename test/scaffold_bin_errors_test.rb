require_relative "test_helper"
require "tmpdir"
require "open3"
require "monk/scaffold"
require "pg"

# Each generated bin/ script, run as a developer runs it, with its service
# unreachable or a setting missing: it ends with what failed and how to fix
# it, exit 1, never a backtrace (docs/plan-scaffold.md decision 29).
class ScaffoldBinErrorsTest < Minitest::Test
  include PersistenceTestHelpers

  UNREACHABLE = { "DB_HOST" => "127.0.0.1", "DB_PORT" => "5999" }.freeze

  def test_bin_setup_db_with_postgres_not_running
    in_app(postgres: true) do |dest|
      err = assert_explained(dest, "bin/setup_db", UNREACHABLE)

      assert_includes err, "bin/setup_db: can't connect to Postgres at 127.0.0.1:5999"
      assert_includes err, "--name demo_app_pg postgres:16"
    end
  end

  def test_bin_migrate_with_a_missing_database
    skip_unless_postgres_available

    in_app(postgres: true) do |dest|
      err = assert_explained(dest, "bin/migrate", postgres_env.merge("DB_NAME" => "monk_no_such_db"), "status")

      assert_includes err, %(bin/migrate: database "monk_no_such_db" doesn't exist)
      assert_includes err, "createdb -h"
    end
  end

  def test_bin_console_with_a_missing_setting
    in_app(auth: true) do |dest|
      File.write(File.join(dest, ".env"), File.read(File.join(dest, ".env")).gsub(/^AUTH_SECRET=.*\n/, ""))

      err = assert_explained(dest, "bin/console", { "AUTH_SECRET" => nil })

      assert_includes err, "bin/console: AUTH_SECRET is not set."
    end
  end

  def test_bin_jobs_with_postgres_not_running
    in_app(jobs: true) do |dest|
      err = assert_explained(dest, "bin/jobs", UNREACHABLE)

      assert_includes err, "bin/jobs: can't connect to Postgres at 127.0.0.1:5999"
    end
  end

  def test_bin_websocket_server_with_redis_not_running
    in_app(redis: true) do |dest|
      err = assert_explained(dest, "bin/websocket_server", { "REDIS_URL" => "redis://127.0.0.1:6999/0" })

      assert_includes err, "bin/websocket_server: can't connect to Redis at redis://127.0.0.1:6999/0"
    end
  end

  def test_the_live_bin_websocket_server_with_redis_not_running
    in_app(live: true, redis: true) do |dest|
      err = assert_explained(dest, "bin/websocket_server", { "REDIS_URL" => "redis://127.0.0.1:6999/0" })

      assert_includes err, "bin/websocket_server: can't connect to Redis at redis://127.0.0.1:6999/0"
    end
  end

  private

  def assert_explained(dest, script, env, *)
    env = { "BUNDLE_GEMFILE" => File.expand_path("../Gemfile", __dir__), "MONK_ENV" => "development" }.merge(env)
    _out, err, status = Open3.capture3(env, RbConfig.ruby, "-W0", script, *, chdir: dest, stdin_data: "")

    assert_equal 1, status.exitstatus, err
    refute_match(/\.rb:\d+:in /, err, "no backtrace")
    err
  end

  def postgres_env
    opts = pg_test_opts
    { "DB_HOST" => opts[:host], "DB_PORT" => opts[:port].to_s, "DB_USER" => opts[:user],
      "DB_PASSWORD" => opts[:password], }
  end

  def in_app(**flags)
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest, **flags).write!
      yield dest
    end
  end
end
