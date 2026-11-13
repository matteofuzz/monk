require_relative "../test_helper"
require "json"

# monk add pwa (docs/plan-pwa-push.md, part A): the manifest with the
# app's name filled in, placeholder icons, sw.js, no service and no env.
class GeneratorsPwaTest < Minitest::Test
  include GeneratorTestHelpers

  ICONS = %w[icon-192.png icon-512.png icon-maskable-512.png apple-touch-icon.png].freeze

  def test_writes_the_config_service_worker_and_icons
    with_new_app(:pwa) do |dest|
      assert_equal template("pwa/config/pwa.rb"), generated(dest, "config/pwa.rb")
      assert_equal template("pwa/public/sw.js"), generated(dest, "public/sw.js")
      ICONS.each do |icon|
        assert_equal File.binread(File.join(Monk::Generator::TEMPLATES_DIR, "pwa/public/icons", icon)),
          File.binread(File.join(dest, "public/icons", icon)), icon
      end
      assert_includes generated(dest, "config/load.rb"), "storage pwa", "config/load.rb already requires it"
    end
  end

  def test_the_manifest_carries_the_apps_name
    with_new_app(:pwa) do |dest|
      manifest = JSON.parse(generated(dest, "public/manifest.webmanifest"))

      assert_equal %w[shop shop], manifest.values_at("name", "short_name")
      refute_includes generated(dest, "public/manifest.webmanifest"), "{{app}}"
    end
  end

  # sw.js mustn't get between Live's resync and the network.
  def test_the_service_worker_has_no_fetch_handler
    refute_match(/addEventListener\(\s*["']fetch["']/, template("pwa/public/sw.js"))
  end

  def test_an_apps_own_icon_is_kept_and_reported_skipped
    with_new_app do |dest|
      write_file(dest, "public/icons/icon-192.png", "mine")

      result = add_modules(dest, :pwa)

      assert_equal :ok, result.status
      assert_equal "mine", generated(dest, "public/icons/icon-192.png")
      assert_includes result.skipped.map { |entry| entry[:path] }, "public/icons/icon-192.png"
    end
  end

  def test_needs_no_other_module_service_or_env
    with_new_app do |dest|
      result = add_modules(dest, :pwa)

      assert_equal([:pwa], result.modules.map { |entry| entry[:name] })
      assert_empty result.services
      assert_empty result.env
      refute File.exist?(File.join(dest, ".env"))
      assert_includes result.to_text, "replace the placeholder icons in public/icons/"
    end
  end

  def test_adding_pwa_again_changes_nothing
    with_new_app(:pwa) do |dest|
      result = add_modules(dest, :pwa)

      refute result.written
      assert_equal "pwa is already installed — nothing to do.\n", result.to_text
    end
  end

  def test_json_output
    with_new_app do |dest|
      json = JSON.parse(add_modules(dest, :pwa).to_json)

      roles = json["files"].to_h { |entry| [entry["path"], entry["role"]] }
      assert_equal "wiring", roles["public/manifest.webmanifest"]
      assert_equal "wiring", roles["public/sw.js"]
      assert_equal "view", roles["public/icons/icon-512.png"]
      assert_equal "test", roles["test/pwa_test.rb"]
    end
  end

  def test_the_apps_own_tests_pass
    with_new_app(:pwa) { |dest| assert_generated_tests_pass(dest) }
  end
end
