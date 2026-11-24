require_relative "test_helper"

# Monk::Auth works end to end without any route: a login link and code are
# created, sent by config/auth.rb's deliver: (AuthMailer, to log/test.log
# here), and redeemed into a session. SETUP.md, auth.
class AuthTest < Minitest::Test
  # Lifts the login-email rate limit, so the next test can ask for a link
  # for the same address at once.
  def teardown
    Monk::Auth.clear_login_requests!
  end

  def test_a_login_link_is_sent_and_redeems_into_a_session
    email = "login-check-#{rand(1_000_000)}@example.test"
    login = Monk::Auth.request_login(email)

    Monk::Auth.deliver_link(
      email: email, link: Monk::Auth.login_link(login[:token]), token: login[:token], code: login[:code],
    )

    log = File.read(File.expand_path("../log/test.log", __dir__))
    assert_includes log, Monk::Auth.login_link(login[:token])
    assert_includes log, "#{login[:code]} is your"
    session = Monk::Auth.redeem(login[:token])
    assert_equal email, Monk::Auth.verify(session[:token])
  end

  def test_the_code_redeems_into_a_session_too
    email = "code-check-#{rand(1_000_000)}@example.test"
    login = Monk::Auth.request_login(email)

    session = Monk::Auth.redeem_code(email, login[:code])

    assert_equal email, Monk::Auth.verify(session[:token])
  end
end
