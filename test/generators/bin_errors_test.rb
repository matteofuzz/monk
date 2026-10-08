require_relative "../test_helper"
require "pg"

# Each generated bin/ script, run as a developer runs it, with its service
# unreachable or a setting missing: it ends with what failed and how to fix
# it, exit 1, never a backtrace (docs/history/plan-scaffold.md decision 29).
class GeneratorsBinErrorsTest < Minitest::Test
  include GeneratorTestHelpers
  include PersistenceTestHelpers

  UNREACHABLE = { "DB_HOST" => "127.0.0.1", "DB_PORT" => "5999" }.freeze
  NO_REDIS = { "REDIS_URL" => "redis://127.0.0.1:6999/0" }.freeze

  def test_bin_setup_db_with_postgres_not_running
    with_new_app(:postgres) do |dest|
      err = assert_explained(dest, "bin/setup_db", UNREACHABLE)

      assert_includes err, "bin/setup_db: can't connect to Postgres at 127.0.0.1:5999"
      assert_includes err, "docker run --rm -d -p 5999:5432 -e POSTGRES_PASSWORD=postgres --name shop_pg postgres:16"
    end
  end

  def test_bin_migrate_with_a_missing_database
    skip_unless_postgres_available

    with_new_app(:postgres) do |dest|
      opts = pg_test_opts
      env = { "DB_HOST" => opts[:host], "DB_PORT" => opts[:port].to_s, "DB_USER" => opts[:user],
              "DB_PASSWORD" => opts[:password], "DB_NAME" => "monk_no_such_db", }
      err = assert_explained(dest, "bin/migrate", env, "status")

      assert_includes err, %(bin/migrate: database "monk_no_such_db" doesn't exist)
      assert_includes err, "createdb -h"
    end
  end

  def test_bin_console_with_a_missing_setting
    with_new_app(:auth) do |dest|
      File.write(File.join(dest, ".env"), generated(dest, ".env").gsub(/^AUTH_SECRET=.*\n/, ""))

      err = assert_explained(dest, "bin/console", { "AUTH_SECRET" => nil })
      assert_includes err, "bin/console: AUTH_SECRET is not set."
    end
  end

  def test_bin_jobs_with_postgres_not_running
    with_new_app(:jobs) do |dest|
      err = assert_explained(dest, "bin/jobs", UNREACHABLE)
      assert_includes err, "bin/jobs: can't connect to Postgres at 127.0.0.1:5999"
    end
  end

  def test_bin_websocket_server_with_redis_not_running
    with_new_app(:websocket, options: { transport: "redis" }) do |dest|
      uncomment_examples(dest) # a handler to serve: the chat example

      err = assert_explained(dest, "bin/websocket_server", NO_REDIS)
      assert_includes err, "bin/websocket_server: can't connect to Redis at redis://127.0.0.1:6999/0"
    end
  end

  def test_bin_websocket_server_of_a_live_app_with_redis_not_running
    with_new_app(:live, options: { transport: "redis" }) do |dest|
      err = assert_explained(dest, "bin/websocket_server", NO_REDIS)

      assert_includes err, "bin/websocket_server: can't connect to Redis at redis://127.0.0.1:6999/0"
    end
  end

  private

  def assert_explained(dest, script, env, *)
    out, status = run_generated_script(dest, script, env.merge("MONK_ENV" => "development"), *)

    assert_equal 1, status.exitstatus, out
    refute_match(/\.rb:\d+:in /, out, "no backtrace")
    out
  end
end
