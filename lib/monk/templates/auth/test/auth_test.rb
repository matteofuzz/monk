require_relative "test_helper"

# Monk::Auth works end to end without any route: a login link is created,
# sent by config/auth.rb's deliver: (AuthMailer, to log/test.log here), and
# redeemed into a session. SETUP.md, auth.
class AuthTest < Minitest::Test
  def test_a_login_link_is_sent_and_redeems_into_a_session
    email = "login-check-#{rand(1_000_000)}@example.test"
    token = Monk::Auth.request_login(email)

    Monk::Auth.deliver_link(email: email, link: Monk::Auth.login_link(token), token: token)

    assert_includes File.read(File.expand_path("../log/test.log", __dir__)), Monk::Auth.login_link(token)
    session = Monk::Auth.redeem(token)
    assert_equal email, Monk::Auth.verify(session[:token])
  end
end
