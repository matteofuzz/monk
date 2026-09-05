require_relative "test_helper"

class SettingsBootTest < Minitest::Test
  def test_missing_required_key_raises_at_boot
    with_settings do
      Monk::Settings.configure { required :monk_test_secret }
      app = Class.new(Monk::Base) { get("/x") { "hi" } }

      error = assert_raises(Monk::MissingSettingError) { app.freeze! }

      assert_match(/monk_test_secret/, error.message)
    end
  end

  def test_present_required_key_boots_fine_and_stays_readable
    with_settings do
      with_env("MONK_TEST_SECRET", "shh") do
        Monk::Settings.configure { required :monk_test_secret }
        Class.new(Monk::Base) { get("/x") { "hi" } }.freeze!

        assert_equal "shh", Monk::Settings[:monk_test_secret]
      end
    end
  end

  def test_readable_from_a_real_worker_ractor_after_boot
    with_settings do
      with_env("MONK_TEST_SECRET", "shh") do
        Monk::Settings.configure { required :monk_test_secret }
        Class.new(Monk::Base) { get("/x") { "hi" } }.freeze!

        result = Ractor.new { Monk::Settings[:monk_test_secret] }.value

        assert_equal "shh", result
      end
    end
  end

  def test_configuring_again_after_boot_raises
    with_settings do
      Class.new(Monk::Base) { get("/x") { "hi" } }.freeze!

      assert_raises(Monk::SettingsFrozenError) do
        Monk::Settings.configure { optional :monk_test_late, default: "x" }
      end
    end
  end
end
