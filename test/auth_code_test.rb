require_relative "test_helper"
require "monk/auth"

# 0.28: a 6-digit sign-in code beside the magic link, redeeming the same
# login token (docs/plan-onboarding.md, decisions 5-6).
class AuthCodeTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthDatabaseTest

  DB_NAME = :auth_code_test_db

  def setup
    super
    setup_auth_tables(DB_NAME)
  end

  def test_request_login_returns_the_token_and_a_six_digit_code_storing_only_an_hmac_of_it
    login = Monk::Auth.request_login("a@b.com")

    assert_kind_of String, login[:token]
    assert_match(/\A\d{6}\z/, login[:code])
    row = fetch_login_token(email: "a@b.com")
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", "s3cr3t", login[:code]), row["code_hash"]
    refute_includes row.values.join, login[:code]
    assert_equal 0, row["code_attempts"].to_i
  end

  def test_request_login_strips_and_downcases_the_address
    Monk::Auth.request_login("  Ann@Example.TEST ")

    refute_nil fetch_login_token(email: "ann@example.test")
  end

  def test_redeem_code_returns_a_session_like_redeem
    login = Monk::Auth.request_login("a@b.com", redirect_to: "/dashboard")

    session = Monk::Auth.redeem_code("a@b.com", login[:code])

    assert_equal "a@b.com", session[:subject]
    assert_equal "/dashboard", session[:redirect_to]
    assert_equal "a@b.com", Monk::Auth.verify(session[:token])
  end

  def test_redeem_code_normalizes_the_address_like_request_login
    login = Monk::Auth.request_login("ann@example.test")

    refute_nil Monk::Auth.redeem_code(" ANN@example.test", login[:code])
  end

  def test_the_code_and_the_link_redeem_one_token_so_the_other_stops_working
    by_code = Monk::Auth.request_login("a@b.com")
    refute_nil Monk::Auth.redeem_code("a@b.com", by_code[:code])
    assert_nil Monk::Auth.redeem(by_code[:token])

    by_link = Monk::Auth.request_login("a@b.com")
    refute_nil Monk::Auth.redeem(by_link[:token])
    assert_nil Monk::Auth.redeem_code("a@b.com", by_link[:code])
  end

  def test_a_new_code_makes_the_previous_one_stop_working
    first = Monk::Auth.request_login("a@b.com")
    # One in a million, two requests draw the same code: ask again.
    second = Monk::Auth.request_login("a@b.com") until second && second[:code] != first[:code]

    assert_nil Monk::Auth.redeem_code("a@b.com", first[:code])
    refute_nil Monk::Auth.redeem_code("a@b.com", second[:code])
  end

  def test_redeem_code_returns_nil_for_an_expired_token
    login = Monk::Auth.request_login("a@b.com")
    Monk::Persistence::Pg.checkout(DB_NAME) { |c| c.exec("UPDATE login_tokens SET expires_at = now() - interval '1 second'") }

    assert_nil Monk::Auth.redeem_code("a@b.com", login[:code])
  end

  def test_redeem_code_returns_nil_for_malformed_input_without_counting_it
    Monk::Auth.request_login("a@b.com")

    [nil, "", "12345", "1234567", "abcdef", 123_456].each { |code| assert_nil Monk::Auth.redeem_code("a@b.com", code) }
    assert_nil Monk::Auth.redeem_code("", "123456")
    assert_equal 0, fetch_login_token(email: "a@b.com")["code_attempts"].to_i
  end

  def test_a_wrong_code_counts_an_attempt_and_the_fifth_burns_the_token
    login = Monk::Auth.request_login("a@b.com")
    wrong = wrong_code(login[:code])

    4.times { assert_nil Monk::Auth.redeem_code("a@b.com", wrong) }
    assert_equal 4, fetch_login_token(email: "a@b.com")["code_attempts"].to_i
    assert_nil fetch_login_token(email: "a@b.com")["used_at"]

    assert_nil Monk::Auth.redeem_code("a@b.com", wrong)
    refute_nil fetch_login_token(email: "a@b.com")["used_at"]
    assert_nil Monk::Auth.redeem_code("a@b.com", login[:code])
    assert_nil Monk::Auth.redeem(login[:token])
  end

  def test_ten_failures_in_an_hour_lock_the_address_across_new_codes
    3.times do
      login = Monk::Auth.request_login("a@b.com")
      4.times { Monk::Auth.redeem_code("a@b.com", wrong_code(login[:code])) }
    end
    # 12 failures: the address is locked, even for a fresh, right code.
    login = Monk::Auth.request_login("a@b.com")

    assert_nil Monk::Auth.redeem_code("a@b.com", login[:code])
    refute_nil Monk::Auth.redeem(login[:token]), "the link still works"
  end

  def test_the_lock_lifts_after_the_hour
    login = Monk::Auth.request_login("a@b.com")
    Monk::Persistence::Pg.checkout(DB_NAME) do |c|
      c.exec("INSERT INTO login_requests (email, requested_at, code_failures, code_failures_since) " \
             "VALUES ('a@b.com', now(), 10, now() - interval '61 minutes')")
    end

    refute_nil Monk::Auth.redeem_code("a@b.com", login[:code])
  end

  def test_counting_failures_does_not_hold_back_the_next_login_email
    login = Monk::Auth.request_login("fresh@b.com")
    Monk::Auth.redeem_code("fresh@b.com", wrong_code(login[:code]))

    assert Monk::Auth.allow_login_request?("fresh@b.com")
  end

  def test_sweep_keeps_a_login_request_while_its_failures_count
    login = Monk::Auth.request_login("a@b.com")
    Monk::Auth.redeem_code("a@b.com", wrong_code(login[:code]))

    Monk::Auth.sweep!

    assert_equal 1, Monk::Persistence::Pg.checkout(DB_NAME) { |c| c.exec("SELECT 1 FROM login_requests").ntuples }
  end

  private

  def fetch_login_token(email:)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("SELECT * FROM login_tokens WHERE email = $1 ORDER BY id DESC", [email]).first
    end
  end

  def wrong_code(code) = format("%06d", (Integer(code, 10) + 1) % 1_000_000)
end
