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
end
