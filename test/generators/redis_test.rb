require_relative "../test_helper"

# monk add redis (docs/plan-scaffold.md, "redis"): a module of its own, for
# a cache as much as for WebSocket's transport.
class GeneratorsRedisTest < Minitest::Test
  include GeneratorTestHelpers
  include RedisTestHelpers

  def test_writes_the_redis_setting_and_gem
    with_new_app(:redis) do |dest|
      assert_equal template("redis/config/redis.rb"), generated(dest, "config/redis.rb")
      assert_includes generated(dest, "Gemfile"), %(gem "redis", "~> 5.0")
      %w[.env .env.test .env.example].each do |file|
        assert_includes generated(dest, file), "REDIS_URL=redis://localhost:6379/0\n"
      end
    end
  end

  def test_needs_nothing_else
    with_new_app do |dest|
      result = add_modules(dest, :redis)

      assert_equal [:redis], result.modules.map { |entry| entry[:name] }
      refute File.exist?(File.join(dest, "config/persistence.rb"))
    end
  end

  def test_redis_url_is_required_outside_development_and_test
    with_new_app(:redis) do |dest|
      File.delete(File.join(dest, ".env")) # never deployed: .dockerignore leaves it out
      env = { "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__), "MONK_ENV" => "production",
              "REDIS_URL" => nil, }
      script = %(require "./config/settings"; require "./config/redis"; Monk::Settings.freeze_registry!)
      out, status = Open3.capture2e(env, RbConfig.ruby, "-rbundler/setup", "-e", script, chdir: dest)

      refute status.success?
      assert_includes out, "required setting :redis_url"
    end
  end

  def test_the_apps_own_tests_pass
    skip_unless_redis_available

    with_new_app(:redis) { |dest| assert_generated_tests_pass(dest, "REDIS_URL" => redis_test_url) }
  end
end
