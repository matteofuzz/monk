require_relative "../test_helper"
require "pg"

# Every `# monk:example` block, uncommented in a generated app, works:
# docs/plan-scaffold.md decision 15. The app's own suite runs with a probe
# test per example, so an API change that breaks an example breaks this
# test instead of the first app that copies it.
class GeneratorsExamplesTest < Minitest::Test
  include GeneratorTestHelpers
  include PersistenceTestHelpers
  include RedisTestHelpers

  # The modules whose examples are checked: every module with a generator.
  MODULES = %i[postgres redis mail auth].freeze

  # What each example does once uncommented, as test methods in the app.
  # `request` (defined below, in PROBE_HELPERS) goes through the booted APP.
  PROBES = {
    "postgres-model" => <<~RUBY,
      def test_postgres_model
        Monk::Persistence::Pg.checkout(:primary) do |conn|
          conn.exec("CREATE TABLE notes (id BIGSERIAL PRIMARY KEY, body TEXT NOT NULL)")
        end

        assert_equal 200, request("POST", "/notes", body: "hello").first
        status, body = request("GET", "/notes")

        assert_equal 200, status
        assert_equal ["hello"], JSON.parse(body)["notes"].map { |note| note["body"] }
      end
    RUBY
    "redis-cache" => <<~RUBY,
      def test_redis_cache
        Redis.new(url: Monk::Settings[:redis_url]).then { |redis| redis.del("cached:now") && redis.close }

        first = JSON.parse(request("GET", "/cached/now")[1])["now"]
        second = JSON.parse(request("GET", "/cached/now")[1])["now"]

        refute_nil first
        assert_equal first, second, "the second request reads the cached value"
      end
    RUBY
    "mail-welcome" => <<~RUBY,
      def test_mail_welcome
        assert_equal 200, request("POST", "/welcome", email: "ann@example.test", name: "Ann").first

        assert_includes File.read(File.expand_path("../log/test.log", __dir__)), %(subject="Welcome, Ann")
      end
    RUBY
    "auth-routes" => <<~RUBY,
      def test_auth_routes
        status, body = request("GET", "/login")
        assert_equal 200, status
        assert_includes body, %(id="login")

        email = "probe-\#{rand(1_000_000)}@example.test"
        assert_equal 200, request("POST", "/auth/request", email: email).first
        token = File.read(File.expand_path("../log/test.log", __dir__)).scan(%r{/auth/callback/([\\w-]+)}).last.first

        status, _body, headers = request("GET", "/auth/callback/\#{token}")
        assert_equal 302, status
        cookies = Array(headers["set-cookie"]).to_h { |cookie| cookie.split(";").first.split("=", 2) }
        logged_in = { "HTTP_COOKIE" => cookies.map { |name, value| "\#{name}=\#{value}" }.join("; ") }
        assert_equal [200, %({"email":"\#{email}"})], request("GET", "/me", nil, logged_in).first(2)

        csrf = logged_in.merge("HTTP_X_CSRF_TOKEN" => cookies["csrf_token"])
        assert_equal 200, request("POST", "/auth/logout", nil, csrf).first
        assert_equal 401, request("GET", "/me", nil, logged_in).first

        statuses = Array.new(6) { request("POST", "/auth/request", email: email).first }
        assert_includes statuses, 429, "the rate limit stops a flood of links"
      end
    RUBY
  }.freeze

  PROBE_HELPERS = <<~RUBY.freeze
    require "json"
    require "rack"

    # Monk reads params from the query string and JSON bodies. Returns
    # [status, body, headers].
    def request(method, path, json = nil, env = {})
      options = { method: method }
      options.merge!(input: JSON.generate(json), "CONTENT_TYPE" => "application/json") if json
      status, headers, body = APP.call(Rack::MockRequest.env_for(path, **options).merge(env))
      [status, body.join, headers]
    end
  RUBY

  def test_every_example_has_a_probe
    with_new_app(*MODULES) do |dest|
      assert_equal PROBES.keys.sort, example_tags(dest).sort
    end
  end

  def test_every_example_works_uncommented
    with_new_app(*MODULES) do |dest|
      uncomment_examples(dest)
      write_probes(dest)

      with_generated_database do |database|
        env = database.merge("REDIS_URL" => redis_test_url)
        out, status = run_generated_script(dest, "bin/setup_db", env)
        assert status.success?, out

        assert_generated_tests_pass(dest, env)
      end
    end
  end

  private

  def example_files(dest)
    Dir.glob("{app,config}/**/*.rb", base: dest).select { |path| generated(dest, path).include?("monk:example") }
  end

  def example_tags(dest)
    example_files(dest).flat_map { |path| generated(dest, path).scan(/#\s*monk:example\s+(\S+)/).flatten }.uniq
  end

  # Inside each block, "# code" becomes "code" and "# # note" stays a
  # comment, "# note"; the marker lines stay as they are.
  def uncomment_examples(dest)
    example_files(dest).each do |path|
      inside = false
      lines = generated(dest, path).lines.map do |line|
        if line.match?(/#\s*monk:example\s/)
          inside = true
          line
        elsif inside && line.strip == "# monk:end"
          inside = false
          line
        elsif inside
          line.sub(/\A(\s*)# ?/, '\1')
        else
          line
        end
      end
      File.write(File.join(dest, path), lines.join)
    end
  end

  def write_probes(dest)
    body = [PROBE_HELPERS, *example_tags(dest).map { |tag| PROBES.fetch(tag) }].join("\n")
    File.write(File.join(dest, "test/examples_probe_test.rb"), <<~RUBY)
      require_relative "test_helper"

      class ExamplesProbeTest < Minitest::Test
      #{body.gsub(/^(?=.)/, "  ")}
      end
    RUBY
  end
end
