require_relative "test_helper"

class SettingsTest < Minitest::Test
  def test_required_key_reads_from_env
    with_settings do
      with_env("MONK_TEST_API_KEY", "secret") do
        Monk::Settings.configure { required :monk_test_api_key }

        assert_equal "secret", Monk::Settings[:monk_test_api_key]
      end
    end
  end

  def test_optional_key_falls_back_to_its_default
    with_settings do
      with_env("MONK_TEST_PORT", nil) do
        Monk::Settings.configure { optional :monk_test_port, default: "9292" }

        assert_equal "9292", Monk::Settings[:monk_test_port]
      end
    end
  end

  def test_optional_key_prefers_env_over_its_default
    with_settings do
      with_env("MONK_TEST_PORT", "1234") do
        Monk::Settings.configure { optional :monk_test_port, default: "9292" }

        assert_equal "1234", Monk::Settings[:monk_test_port]
      end
    end
  end

  def test_declaring_the_same_key_twice_raises
    with_settings do
      Monk::Settings.configure { required :monk_test_api_key }

      error = assert_raises(Monk::DuplicateSettingError) do
        Monk::Settings.configure { optional :monk_test_api_key, default: "x" }
      end

      assert_match(/monk_test_api_key/, error.message)
    end
  end

  def test_reading_an_undeclared_key_raises
    with_settings do
      error = assert_raises(Monk::UnknownSettingError) { Monk::Settings[:monk_test_mystery] }

      assert_match(/monk_test_mystery/, error.message)
    end
  end

  def test_reset_clears_declared_keys
    with_settings do
      Monk::Settings.configure { required :monk_test_api_key }
      Monk::Settings.reset!

      assert_raises(Monk::UnknownSettingError) { Monk::Settings[:monk_test_api_key] }
    end
  end

  def test_log_level_defaults_to_info
    with_settings { with_env("LOG_LEVEL", nil) { assert_equal "info", Monk::Settings[:log_level] } }
  end

  def test_log_level_reads_from_env
    with_settings { with_env("LOG_LEVEL", "debug") { assert_equal "debug", Monk::Settings[:log_level] } }
  end

  # public_url and live_ws_url: declared by the app, read by Monk, so
  # checked at Boot (docs/plan-boot-settings-checks.md).

  def test_public_url_must_be_an_origin_in_every_environment
    %w[development test production].each do |env|
      %w[https://app.monkrb.org/ https://app.monkrb.org/app app.monkrb.org https://app.monkrb.org?x=1].each do |url|
        error = assert_raises(Monk::InvalidSettingError, "#{url} in #{env}") { boot(env, public_url: url) }
        assert_match(/PUBLIC_URL must be an origin/, error.message)
      end
    end
  end

  def test_public_url_must_be_https_outside_development_and_test
    %w[staging production].each do |env|
      error = assert_raises(Monk::InvalidSettingError) { boot(env, public_url: "http://app.monkrb.org") }
      assert_match(/must be https:/, error.message)
    end
    %w[development test].each { |env| boot(env, public_url: "http://localhost:9292") }
  end

  def test_public_url_on_a_placeholder_host_is_refused_outside_development_and_test
    %w[https://app.example.com https://example.org https://shop.example https://app.test https://x.invalid
       https://app.example.com:8443].each do |url|
      error = assert_raises(Monk::InvalidSettingError, url) { boot("production", public_url: url) }
      assert_match(/is a placeholder/, error.message)
    end
    boot("test", public_url: "https://app.example.com")
  end

  def test_public_url_accepts_real_hosts_localhost_and_ips_in_production
    %w[https://app.monkrb.org https://localhost https://localhost:8443 https://192.0.2.10 https://example.community
       https://notexample.com].each do |url|
      assert boot("production", public_url: url), url
    end
  end

  def test_live_ws_url_must_be_wss_outside_development_and_test
    error = assert_raises(Monk::InvalidSettingError) do
      boot("production", public_url: "https://app.monkrb.org", live_ws_url: "ws://app.monkrb.org/ws")
    end
    assert_match(/LIVE_WS_URL must be wss:/, error.message)

    boot("production", public_url: "https://app.monkrb.org", live_ws_url: "wss://app.monkrb.org/ws")
    boot("development", live_ws_url: "ws://localhost:9293")
  end

  def test_apps_without_public_url_or_live_ws_url_boot_as_before
    assert boot("production")
  end

  private

  def boot(env, public_url: nil, live_ws_url: nil)
    with_settings do
      with_env("MONK_ENV", env) do
        with_env("PUBLIC_URL", public_url) do
          with_env("LIVE_WS_URL", live_ws_url) do
            Monk::Settings.configure do
              optional :public_url, default: "http://localhost:9292" if public_url
              optional :live_ws_url, default: "ws://localhost:9293" if live_ws_url
            end
            Monk::Settings.freeze_registry!
            Monk::Settings.booted?
          end
        end
      end
    end
  end
end
