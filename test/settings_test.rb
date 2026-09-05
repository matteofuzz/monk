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
end
