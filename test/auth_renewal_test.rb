require_relative "test_helper"
require "monk/auth"

# 0.28: sessions renewed by use, and session_max_age: capping a session's
# whole life (docs/plan-onboarding.md, decision 8).
class AuthRenewalTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthDatabaseTest

  DB_NAME = :auth_renewal_test_db
  TTL = 1_209_600
  DAY = 86_400

  ME = proc { |ctx| ctx.current_subject.to_s }

  def setup
    super
    setup_auth_tables(DB_NAME)
  end

  def test_a_session_with_more_than_half_its_ttl_left_is_not_written
    session = new_session
    before = session_row(session)

    _status, headers, body = app.call(with_cookie(session))

    assert_equal "a@b.com", body.join
    assert_equal before["expires_at"], session_row(session)["expires_at"]
    assert_nil session_cookie(headers)
  end

  def test_a_session_past_half_its_ttl_moves_to_now_plus_the_ttl_and_reissues_both_cookies
    session = new_session
    expire_in(session, 3 * DAY)

    _status, headers, body = app.call(with_cookie(session))

    assert_equal "a@b.com", body.join
    assert_in_delta Time.now + TTL, row_expires_at(session), 5
    assert_in_delta TTL, max_age(session_cookie(headers)), 5
    assert_in_delta TTL, max_age(csrf_cookie(headers)), 5
    assert_equal "session_token=#{session[:token]}", session_cookie(headers).split(";").first
  end

  def test_a_bearer_request_renews_the_row_without_cookies
    session = new_session
    expire_in(session, 3 * DAY)
    env = env_for("GET", "/me")
    env["HTTP_AUTHORIZATION"] = "Bearer #{session[:token]}"

    _status, headers, body = app.call(env)

    assert_equal "a@b.com", body.join
    assert_in_delta Time.now + TTL, row_expires_at(session), 5
    assert_nil headers["set-cookie"]
  end

  def test_two_requests_together_renew_once
    session = new_session
    expire_in(session, 3 * DAY)

    first = Monk::Auth.verified_session(session[:token], renew: true)
    second = Monk::Auth.verified_session(session[:token], renew: true)

    assert first[:renewed]
    refute second[:renewed]
    assert_equal "a@b.com", second[:subject]
  end

  def test_verify_never_renews
    session = new_session
    expire_in(session, 3 * DAY)
    before = row_expires_at(session)

    assert_equal "a@b.com", Monk::Auth.verify(session[:token])
    assert_in_delta before, row_expires_at(session), 0.001
  end

  def test_session_max_age_caps_a_renewal_at_the_sessions_whole_life
    configure(session_max_age: 30 * DAY)
    session = new_session
    created_at = Time.now - (20 * DAY)
    set_row(session, created_at: created_at, expires_at: Time.now + (3 * DAY))

    assert Monk::Auth.verified_session(session[:token], renew: true)[:renewed]
    assert_in_delta created_at + (30 * DAY), row_expires_at(session), 1
  end

  def test_a_session_already_ending_at_its_cap_is_not_written
    configure(session_max_age: 30 * DAY)
    session = new_session
    set_row(session, created_at: Time.now - (29 * DAY), expires_at: Time.now + DAY + 10)

    refute Monk::Auth.verified_session(session[:token], renew: true)[:renewed]
  end

  def test_a_session_older_than_session_max_age_no_longer_verifies
    configure(session_max_age: 30 * DAY)
    session = new_session
    set_row(session, created_at: Time.now - (31 * DAY), expires_at: Time.now + DAY)

    assert_nil Monk::Auth.verify(session[:token])
    assert_nil Monk::Auth.verified_session(session[:token], renew: true)
  end

  def test_configure_refuses_a_session_max_age_that_is_not_a_positive_integer
    [0, -1, 1.5, "30"].each do |bad|
      error = assert_raises(Monk::InvalidAuthConfigError) { configure(session_max_age: bad) }
      assert_includes error.message, "session_max_age:"
    end
  end

  private

  def configure(**)
    Monk::Auth.configure(db_name: DB_NAME, secret: "s3cr3t", login_ttl: 600, session_ttl: TTL, **)
  end

  def app
    Class.new(Monk::Base) { get("/me", &ME) }
  end

  def new_session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com")[:token])

  def with_cookie(session)
    env = env_for("GET", "/me")
    env["HTTP_COOKIE"] = "session_token=#{session[:token]}; csrf_token=#{Monk::Auth.csrf_token_for(session[:token])}"
    env
  end

  def expire_in(session, seconds) = set_row(session, expires_at: Time.now + seconds)

  def set_row(session, **columns)
    sets = columns.keys.each_with_index.map { |column, i| "#{column} = $#{i + 2}" }.join(", ")
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("UPDATE sessions SET #{sets} WHERE token_hash = $1",
        [Monk::Auth.token_hash(session[:token]), *columns.values],)
    end
  end

  def session_row(session)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("SELECT * FROM sessions WHERE token_hash = $1", [Monk::Auth.token_hash(session[:token])]).first
    end
  end

  def row_expires_at(session)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("SELECT extract(epoch FROM expires_at)::float8 FROM sessions WHERE token_hash = $1",
        [Monk::Auth.token_hash(session[:token])],).getvalue(0, 0).then { |epoch| Time.at(Float(epoch)) }
    end
  end

  def session_cookie(headers) = Array(headers["set-cookie"]).find { |c| c.start_with?("session_token=") }
  def csrf_cookie(headers) = Array(headers["set-cookie"]).find { |c| c.start_with?("csrf_token=") }
  def max_age(cookie) = Integer(cookie[/max-age=(\d+)/i, 1])
end
