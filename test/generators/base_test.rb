require_relative "../test_helper"

# `monk new shop`: the bare app every module is added on top of
# (docs/plan-scaffold.md, "base").
class GeneratorsBaseTest < Minitest::Test
  include GeneratorTestHelpers

  def test_writes_the_bare_app_from_the_templates
    with_new_app do |dest|
      %w[Gemfile config.ru config/settings.rb config/load.rb app/app.rb app/views/layouts/app.erb
         app/views/index.erb Dockerfile Rakefile test/test_helper.rb test/app_test.rb].each do |path|
        assert_equal template("base/#{path}"), generated(dest, path), path
      end
      assert File.executable?(File.join(dest, "bin/server"))
      %w[models presenters helpers mailers broadcasts jobs routes].each do |role|
        assert File.exist?(File.join(dest, "app/#{role}/.keep")), role
      end
    end
  end

  # WebSocket is a module of its own now (docs/adr/0017).
  def test_has_no_websocket_server
    with_new_app do |dest|
      refute File.exist?(File.join(dest, "bin/websocket_server"))
    end
  end

  def test_writes_setup_md_agents_md_and_a_claude_md_that_imports_it
    with_new_app do |dest|
      assert generated(dest, "SETUP.md").start_with?("<!-- monk:module base -->\n# Setting up shop\n")
      assert_includes generated(dest, "AGENTS.md"), "# shop: notes for coding agents"
      assert_includes generated(dest, "AGENTS.md"), "## Modules\n"
      assert_equal "@AGENTS.md\n", generated(dest, "CLAUDE.md")
    end
  end

  def test_adding_base_again_changes_nothing
    with_new_app do |dest|
      result = add_modules(dest, :base)

      refute result.written
      assert_equal "base is already installed — nothing to do.\n", result.to_text
    end
  end

  def test_the_new_apps_own_tests_pass
    with_new_app { |dest| assert_generated_tests_pass(dest) }
  end

  # The bare app as config.ru runs it: its page and stylesheet, a route in
  # app/routes/ (docs/adr/0017), a helper in app/helpers/, and app code
  # loaded by role, in config/load.rb's order (docs/adr/0015).
  def test_the_app_serves_its_page_and_loads_routes_helpers_and_code_by_role
    with_new_app do |dest|
      write_file(dest, "app/routes/extra.rb", %(class App\n  get("/extra") { probe_greeting }\nend\n))
      write_file(dest, "app/helpers/probe_helpers.rb", <<~RUBY)
        module ProbeHelpers
          def probe_greeting = "hello from app/helpers"
        end
        Monk::Context.include(ProbeHelpers)
      RUBY
      write_file(dest, "app/models/probe.rb", "LOAD_ORDER = [:models]\n")
      %w[presenters helpers mailers broadcasts jobs].each do |role|
        write_file(dest, "app/#{role}/probe_order.rb", "LOAD_ORDER << :#{role}\n")
      end
      write_file(dest, "test/base_probe_test.rb", <<~RUBY)
        require_relative "test_helper"
        require "rack"

        class BaseProbeTest < Minitest::Test
          def get(path) = APP.call(Rack::MockRequest.env_for(path))

          def test_the_page_and_its_stylesheet
            status, headers, body = get("/")
            assert_equal [200, "text/html; charset=utf-8"], [status, headers["content-type"]]
            assert_includes body.join, "<h1>It works</h1>"
            assert_equal "text/css; charset=utf-8", get("/css/app.css")[1]["content-type"]
          end

          def test_a_route_in_app_routes_calling_an_app_helper
            assert_equal "hello from app/helpers", get("/extra")[2].join
          end

          def test_code_loads_by_role_in_order
            assert_equal %i[models presenters helpers mailers broadcasts jobs], LOAD_ORDER
          end
        end
      RUBY

      assert_generated_tests_pass(dest)
    end
  end

  # config/settings.rb loads on its own: without the dotenv gem it's a
  # no-op, and Monk::Settings' built-in :monk_env is readable afterwards.
  def test_config_settings_loads_standalone
    with_new_app do |dest|
      out, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e",
        %(load "config/settings.rb"; print Monk::Settings[:monk_env].class), chdir: dest,)

      assert status.success?, out
      assert_equal "String", out
    end
  end

  # config/load.rb requires the module configs that exist, in Monk's fixed
  # order, whatever order they were added in (docs/plan-scaffold.md
  # decision 6): stub configs print their names.
  def test_config_load_requires_the_module_configs_that_exist_in_monks_order
    Dir.mktmpdir do |dir|
      write_file(dir, "config/load.rb", template("base/config/load.rb"))
      write_file(dir, "config/settings.rb", %(print "settings "\n))
      %w[live jobs mail persistence].each { |name| write_file(dir, "config/#{name}.rb", %(print "#{name} "\n)) }

      out, status = Open3.capture2e(RbConfig.ruby, "-e", %(require "./config/load"), chdir: dir)

      assert status.success?, out
      assert_equal "settings persistence mail jobs live ", out
    end
  end
end
