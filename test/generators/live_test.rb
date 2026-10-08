require_relative "../test_helper"
require "pg"

# monk add live (docs/plan-scaffold.md, "live"): over websocket's registry,
# with a demo in development unless --no-demo.
class GeneratorsLiveTest < Minitest::Test
  include GeneratorTestHelpers
  include PersistenceTestHelpers

  def test_adds_websocket_over_the_installed_transport
    with_new_app(:postgres) do |dest|
      result = add_modules(dest, :live)

      added = result.modules.select { |entry| entry[:action] == :added }
      assert_equal(%i[websocket live], added.map { |entry| entry[:name] })
      assert_includes generated(dest, "config/websocket.rb"), "PgFanout"
      assert_includes generated(dest, "config/live.rb"), "Monk::Live.configure(registry: AppWebSocket::REGISTRY)"
    end
  end

  def test_on_a_bare_app_the_transport_is_a_choice
    with_new_app do |dest|
      assert_equal :missing_choice, add_modules(dest, :live).status
    end
  end

  def test_the_demo_is_on_by_default
    with_new_app(:postgres) do |dest|
      result = add_modules(dest, :live)

      %w[app/routes/demo_live.rb app/views/demo/live.erb app/views/demo/_hits.erb].each do |path|
        assert File.exist?(File.join(dest, path)), path
      end
      assert_includes generated(dest, "config/live.rb"), 'Monk::Live.authorize("demo:hits"'
      assert_includes result.to_text, "open http://localhost:9292/demo/live in two tabs"
      assert result.to_text.end_with?("and its lines in config/live.rb.\n")
    end
  end

  def test_no_demo_leaves_out_its_files_lines_steps_and_closing
    with_new_app(:postgres) do |dest|
      result = add_modules(dest, :live, options: { demo: "off" })

      refute File.exist?(File.join(dest, "app/routes/demo_live.rb"))
      refute File.exist?(File.join(dest, "app/views/demo"))
      refute_includes generated(dest, "config/live.rb"), "demo:hits"
      refute_includes result.to_text, "/demo/live"
      assert_nil result.closing
    end
  end

  def test_the_apps_own_tests_pass
    with_new_app(:live, options: { transport: "postgres" }) do |dest|
      with_generated_database { |env| assert_generated_tests_pass(dest, env) }
    end
  end

  # The demo, in development, as a browser uses it: the page subscribes to
  # its topic, a visitor may, and pressing the button publishes.
  def test_the_demo_works_in_development
    with_new_app(:live, options: { transport: "postgres" }) do |dest|
      File.write(File.join(dest, "test/demo_probe_test.rb"), <<~RUBY)
        require_relative "test_helper"
        require "rack"

        class DemoProbeTest < Minitest::Test
          def test_the_demo
            _status, _headers, body = APP.call(Rack::MockRequest.env_for("/demo/live"))
            assert_includes body.join, %(data-live-topic="demo:hits")
            assert Monk::Live.authorized?(nil, "demo:hits")

            status, headers, = APP.call(Rack::MockRequest.env_for("/demo/live/hit", method: "POST"))
            assert_equal [302, "/demo/live"], [status, headers["location"]]
          end
        end
      RUBY

      with_generated_database { |env| assert_generated_tests_pass(dest, env.merge("MONK_ENV" => "development")) }
    end
  end
end
