require_relative "test_helper"
require "monk/auth"

# AUTH_SECRET present but guessable: refused outside development and test
# (docs/plan-boot-settings-checks.md).
class AuthSecretTest < Minitest::Test
  STRONG = "0123456789abcdef" * 4

  def teardown
    Monk::Auth.reset!
  end

  def test_a_placeholder_secret_is_refused_in_staging_and_production
    %w[staging production].each do |env|
      %w[change-me change-me-dev-secret change-me-and-make-it-long-enough-to-pass].each do |secret|
        error = assert_raises(Monk::InvalidAuthConfigError, "#{secret} in #{env}") { configure(env, secret) }
        assert_includes error.message, "AUTH_SECRET"
        assert_includes error.message, "openssl rand -hex 32"
      end
    end
  end

  def test_a_short_secret_is_refused_in_production
    assert_raises(Monk::InvalidAuthConfigError) { configure("production", "a" * 31) }
    configure("production", "a" * 32)
  end

  def test_a_strong_secret_is_accepted_in_production
    configure("production", STRONG)

    assert_equal STRONG, Monk::Auth.config[:secret]
  end

  def test_development_and_test_keep_their_placeholders
    configure("development", "change-me-dev-secret")
    assert_equal "change-me-dev-secret", Monk::Auth.config[:secret]
    configure("test", "s")
    assert_equal "s", Monk::Auth.config[:secret]
  end

  private

  def configure(env, secret)
    with_settings do
      with_env("MONK_ENV", env) do
        Monk::Auth.configure(db_name: :unused, secret: secret, login_ttl: 600, session_ttl: 1_209_600)
      end
    end
  end
end
