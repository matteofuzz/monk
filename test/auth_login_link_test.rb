require_relative "test_helper"
require "monk/auth"

# Monk::Auth.login_link: the magic link for a token, built from the app's
# public_url (config/settings.rb) and Monk::Auth's callback_path: -- the
# one place the callback route's path is written, read by
# Monk::Auth::SendLoginLink and by the app's own callback route.
class AuthLoginLinkTest < Minitest::Test
  def teardown
    Monk::Auth.reset!
  end

  def test_callback_path_defaults_to_auth_callback
    configure

    assert_equal "/auth/callback", Monk::Auth.config[:callback_path]
  end

  def test_login_link_is_public_url_then_callback_path_then_token
    with_public_url("https://app.example") do
      configure

      assert_equal "https://app.example/auth/callback/abc123", Monk::Auth.login_link("abc123")
    end
  end

  def test_login_link_follows_a_custom_callback_path
    with_public_url("https://app.example") do
      configure(callback_path: "/login/verify")

      assert_equal "https://app.example/login/verify/abc123", Monk::Auth.login_link("abc123")
    end
  end

  def test_a_trailing_slash_on_callback_path_is_dropped
    configure(callback_path: "/login/")

    assert_equal "/login", Monk::Auth.config[:callback_path]
  end

  def test_callback_path_must_be_an_absolute_path
    error = assert_raises(Monk::InvalidAuthConfigError) { configure(callback_path: "auth/callback") }

    assert_includes error.message, "callback_path"
  end

  def test_login_link_before_configure_raises
    assert_raises(Monk::AuthNotConfiguredError) { Monk::Auth.login_link("abc123") }
  end

  private

  def configure(**)
    Monk::Auth.configure(db_name: :unused, secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600, **)
  end

  def with_public_url(url)
    with_settings do
      with_env("PUBLIC_URL", url) do
        Monk::Settings.configure { optional :public_url, default: "http://localhost:9292" }
        yield
      end
    end
  end
end
