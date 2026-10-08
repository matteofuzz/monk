require_relative "../test_helper"
require "pg"

# monk add websocket (docs/plan-scaffold.md decision 13): a transport,
# Postgres or Redis, chosen once, in config/websocket.rb.
class GeneratorsWebSocketTest < Minitest::Test
  include GeneratorTestHelpers
  include PersistenceTestHelpers
  include RedisTestHelpers

  def test_the_transport_is_the_one_installed
    with_new_app(:postgres) do |dest|
      result = add_modules(dest, :websocket)

      assert_equal({ transport: "postgres" }, result.modules.last[:options])
      assert_equal template("websocket/config/websocket_postgres.rb"), generated(dest, "config/websocket.rb")
      assert File.executable?(File.join(dest, "bin/websocket_server"))
    end
  end

  def test_a_chosen_transport_is_added_first
    with_new_app do |dest|
      result = add_modules(dest, :websocket, options: { transport: "redis" })

      assert_equal(%i[redis websocket], result.modules.map { |entry| entry[:name] })
      assert_equal template("websocket/config/websocket_redis.rb"), generated(dest, "config/websocket.rb")
    end
  end

  def test_with_neither_or_both_the_transport_is_a_choice
    with_new_app do |dest|
      result = add_modules(dest, :websocket)

      assert_equal :missing_choice, result.status
      assert_equal 2, result.exit_code
      assert_includes result.message, "none of postgres, redis"
      refute File.exist?(File.join(dest, "config/websocket.rb"))

      add_modules(dest, :postgres, :redis)
      assert_includes add_modules(dest, :websocket).message, "both postgres and redis"
    end
  end

  def test_the_server_with_nothing_to_serve_says_what_to_add
    with_new_app(:websocket, options: { transport: "redis" }) do |dest|
      out, status = run_generated_script(dest, "bin/websocket_server", "REDIS_URL" => redis_test_url)

      assert_equal 1, status.exitstatus, out
      assert_includes out, "bin/websocket_server: nothing to serve. Add live (monk add live)"
    end
  end

  def test_the_apps_own_tests_pass_over_postgres
    with_new_app(:websocket, options: { transport: "postgres" }) do |dest|
      with_generated_database { |env| assert_generated_tests_pass(dest, env) }
    end
  end

  def test_the_apps_own_tests_pass_over_redis
    skip_unless_redis_available

    with_new_app(:websocket, options: { transport: "redis" }) do |dest|
      assert_generated_tests_pass(dest, "REDIS_URL" => redis_test_url)
    end
  end
end
