require_relative "test_helper"

class EnvironmentTest < Minitest::Test
  def test_defaults_to_development_when_unset
    with_settings do
      with_env("MONK_ENV", nil) do
        assert_equal "development", Monk::Settings[:monk_env]
        assert_predicate Monk.env, :development?
      end
    end
  end

  def test_predicates_reflect_the_current_value
    with_settings do
      %w[development test staging production].each do |value|
        with_env("MONK_ENV", value) do
          env = Monk.env

          assert_equal value, env.to_s
          %w[development test staging production].each do |candidate|
            assert_equal(candidate == value, env.public_send("#{candidate}?"), "#{candidate}? for #{value}")
          end
        end
      end
    end
  end

  def test_invalid_value_raises_at_boot_naming_the_value_and_allowed_set
    with_settings do
      with_env("MONK_ENV", "prod") do
        error = assert_raises(Monk::InvalidMonkEnvError) do
          Class.new(Monk::Base) { get("/x") { "hi" } }.freeze!
        end

        assert_match(/"prod"/, error.message)
        assert_match(/development, test, staging, production/, error.message)
      end
    end
  end

  def test_valid_value_boots_fine_and_is_readable_from_a_real_worker_ractor
    with_settings do
      with_env("MONK_ENV", "staging") do
        Class.new(Monk::Base) { get("/x") { "hi" } }.freeze!

        result = Ractor.new { Monk.env.staging? }.value

        assert_equal true, result
      end
    end
  end
end
