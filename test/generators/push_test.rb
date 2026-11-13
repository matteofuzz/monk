require_relative "../test_helper"
require "json"
require "pg"
require "monk/push"

# monk add push (docs/plan-pwa-push.md, B7): needs pwa, jobs and auth;
# writes a fresh VAPID pair to .env and .env.test, its migration, the
# subscribe and notify examples and the on/off switch.
class GeneratorsPushTest < Minitest::Test
  include GeneratorTestHelpers
  include PersistenceTestHelpers

  def test_adds_pwa_jobs_and_auth_first
    with_new_app do |dest|
      result = add_modules(dest, :push)

      added = result.modules.select { |entry| entry[:action] == :added }.map { |entry| entry[:name] }
      assert_equal %i[postgres jobs mail auth pwa push].sort, added.sort
      assert_equal :push, added.last
    end
  end

  def test_each_env_file_gets_its_own_matching_pair
    with_new_app(:push) do |dest|
      development = env_values(dest, ".env")
      test = env_values(dest, ".env.test")

      [development, test].each do |values|
        assert_equal values["VAPID_PUBLIC_KEY"], Monk::Push::Keys.public_key_for(values["VAPID_PRIVATE_KEY"])
        assert_equal "mailto:push@shop.example", values["VAPID_CONTACT"]
      end
      refute_equal development["VAPID_PRIVATE_KEY"], test["VAPID_PRIVATE_KEY"]
      assert_includes generated(dest, ".env.example"), "# VAPID_PRIVATE_KEY=from-monk-push-keys"
    end
  end

  def test_two_apps_get_different_pairs
    pairs = 2.times.map { with_new_app(:push) { |dest| env_values(dest, ".env")["VAPID_PRIVATE_KEY"] } }

    assert_equal 2, pairs.uniq.size
  end

  def test_writes_its_config_migration_examples_and_switch
    with_new_app(:push) do |dest|
      assert_equal template("push/config/push.rb"), generated(dest, "config/push.rb")
      assert_includes Dir.children(File.join(dest, "db/migrate")).join(" "), "_create_push_tables.up.sql"
      routes = generated(dest, "app/routes/push.rb")
      %w[push-subscribe push-notify].each { |tag| assert_includes routes, "# monk:example #{tag}" }
      assert_empty routes.lines.grep(/\A[^#\n]/), "every line is a comment"
      assert_includes generated(dest, "app/views/push/_settings.erb"), "data-push-enable"
      assert_includes generated(dest, "config/load.rb"), "pwa push"
      assert_includes generated(dest, "config/recurring.rb"), "Monk::Push::Sweep"
    end
  end

  def test_lists_what_to_set_before_production
    with_new_app do |dest|
      result = add_modules(dest, :push)

      vapid = %w[VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_CONTACT]
      assert_equal vapid, result.env.map { |entry| entry[:key] } & vapid
      assert_includes result.to_text, %(render "push/_settings", layout: false)
    end
  end

  def test_the_settings_partial_renders
    with_new_app(:push) do |dest|
      require "erb"
      erb = generated(dest, "app/views/push/_settings.erb")

      html = ERB.new(erb).result(binding)

      assert_includes html, "<button type=\"button\" data-push-disable>"
      refute_includes html, "<%"
    end
  end

  def test_adding_push_again_changes_nothing
    with_new_app(:push) do |dest|
      result = add_modules(dest, :push)

      refute result.written
      assert_equal "push is already installed — nothing to do.\n", result.to_text
    end
  end

  def test_the_apps_own_tests_pass
    with_new_app(:push) do |dest|
      with_generated_database do |env|
        out, status = run_generated_script(dest, "bin/setup_db", env)
        assert status.success?, out

        assert_generated_tests_pass(dest, env)
      end
    end
  end

  private

  def env_values(dest, file)
    generated(dest, file).lines.filter_map { |line| line.chomp.split("=", 2) if line.match?(/\A[A-Z_]+=/) }.to_h
  end
end
