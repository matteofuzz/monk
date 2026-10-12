require_relative "test_helper"
require "monk/bin"
require "pg"
require "redis"
require "monk/websocket"

# Monk::Bin.run, what a scaffolded app's bin/ scripts run their work in
# (docs/history/plan-scaffold.md decision 29): a service that's down, a missing
# database or setting ends the script with what failed, which setting, and
# the commands that fix it, exit 1 -- not a backtrace. Anything else is
# re-raised as it is.
class BinTest < Minitest::Test
  SCRIPT = "/apps/shop/bin/setup_db".freeze

  def test_postgres_not_running
    message = explain(PG::ConnectionBad.new(<<~MSG))
      connection to server at "127.0.0.1", port 5999 failed: Connection refused
      \tIs the server running on that host and accepting TCP/IP connections?
    MSG

    assert_includes message, "bin/setup_db: can't connect to Postgres at 127.0.0.1:5999 (DB_HOST/DB_PORT in .env)."
    # The port the app is configured for, so following the command fixes it.
    assert_includes message, "docker run --rm -d -p 5999:5432 -e POSTGRES_PASSWORD=postgres --name shop_pg postgres:16"
    assert_includes message, "then run bin/setup_db again"
  end

  def test_a_missing_database
    message = explain(PG::ConnectionBad.new(
      %(connection to server at "127.0.0.1", port 5432 failed: FATAL:  database "shop_test" does not exist\n),
    ))

    assert_includes message,
      %(bin/setup_db: database "shop_test" doesn't exist on Postgres at 127.0.0.1:5432 (DB_NAME in .env).)
    assert_includes message, "createdb -h 127.0.0.1 -p 5432 -U postgres shop_test"
    refute_includes message, "PGPASSWORD", "never prints the password"
  end

  def test_wrong_credentials
    message = explain(PG::ConnectionBad.new(
      %(connection to server at "127.0.0.1", port 5432 failed: ) +
      %(FATAL:  password authentication failed for user "postgres"\n),
    ))

    assert_includes message, %(Postgres at 127.0.0.1:5432 refused user "postgres" (DB_USER/DB_PASSWORD in .env).)
  end

  def test_redis_not_running_without_printing_its_password
    message = with_env("REDIS_URL", "redis://:s3cret@127.0.0.1:6999/0") do
      explain(Redis::CannotConnectError.new("Connection refused - connect(2) for 127.0.0.1:6999"))
    end

    assert_includes message,
      "bin/setup_db: can't connect to Redis at redis://:***@127.0.0.1:6999/0 (REDIS_URL in .env)."
    assert_includes message, "docker run --rm -d -p 6999:6379 --name shop_redis redis:7"
    refute_includes message, "s3cret"
  end

  # A fanout that can't open its subscriber connection at boot raises
  # ListenError, whatever the underlying error was.
  def test_a_fanout_that_cant_listen
    redis = Monk::WebSocket::ListenError.new("Monk::WebSocket::RedisFanout#listen! couldn't subscribe: whatever")
    pg = Monk::WebSocket::ListenError.new(
      "Monk::WebSocket::PgFanout#listen! couldn't LISTEN: PG::ConnectionBad: connection to server at " \
      "\"127.0.0.1\", port 5999 failed: Connection refused",
    )

    assert_includes with_env("REDIS_URL", nil) { explain(redis) }, "can't connect to Redis at redis://localhost:6379/0"
    assert_includes explain(pg), "can't connect to Postgres at 127.0.0.1:5999"
  end

  def test_a_missing_setting
    error = assert_raises(KeyError) { ENV.fetch("MONK_BIN_TEST_UNSET_SECRET") }

    assert_includes explain(error), "bin/setup_db: MONK_BIN_TEST_UNSET_SECRET is not set."
    assert_includes explain(Monk::MissingSettingError.new(%(required setting :api_key (ENV["API_KEY"]) is not set))),
      "bin/setup_db: API_KEY is not set."
  end

  def test_other_errors_are_not_explained
    assert_nil Monk::Bin.explain(ArgumentError.new("boom"), SCRIPT)
    assert_nil Monk::Bin.explain(KeyError.new("key not found: :x", receiver: {}, key: :x), SCRIPT)
  end

  def test_run_prints_the_explanation_to_stderr_and_exits_with_status_one
    _out, err = capture_io do
      error = assert_raises(SystemExit) { Monk::Bin.run(SCRIPT) { raise PG::ConnectionBad, "x failed: Connection refused" } }
      assert_equal 1, error.status
    end

    assert_includes err, "bin/setup_db: can't connect to Postgres"
  end

  def test_run_re_raises_what_it_cant_explain
    assert_raises(ArgumentError) { Monk::Bin.run(SCRIPT) { raise ArgumentError, "boom" } }
    assert_equal :done, Monk::Bin.run(SCRIPT) { :done }
  end

  private

  def explain(error)
    with_env("DB_HOST", nil) do
      with_env("DB_PORT", nil) do
        with_env("DB_USER", nil) { Monk::Bin.explain(error, SCRIPT) }
      end
    end
  end
end
