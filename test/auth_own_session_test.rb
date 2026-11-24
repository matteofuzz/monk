require_relative "test_helper"
require "monk/auth"

# 0.28: the installed iPhone app gets its own session (docs/plan-onboarding.md,
# decision 9): Monk::Auth.split, own_session!, and the meta register.js reads.
class AuthOwnSessionTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthDatabaseTest

  DB_NAME = :auth_own_session_test_db

  def setup
    super
    setup_auth_tables(DB_NAME)
  end

  def test_split_makes_a_second_session_for_the_same_subject_with_the_same_life
    session = new_session

    split = Monk::Auth.split(session[:token])

    refute_equal session[:token], split[:token]
    assert_equal "a@b.com", split[:subject]
    assert_kind_of Time, split[:expires_at]
    assert_equal "a@b.com", Monk::Auth.verify(split[:token])
    original, copy = rows_for(session, split)
    assert_equal original["expires_at"], copy["expires_at"]
    assert_equal original["created_at"], copy["created_at"]
  end

  def test_the_two_sessions_end_separately
    session = new_session
    split = Monk::Auth.split(session[:token])

    Monk::Auth.revoke(session[:token])

    assert_nil Monk::Auth.verify(session[:token])
    assert_equal "a@b.com", Monk::Auth.verify(split[:token])
  end

  def test_split_returns_nil_without_a_valid_session
    session = new_session
    Monk::Auth.revoke(session[:token])

    assert_nil Monk::Auth.split(session[:token])
    assert_nil Monk::Auth.split("unknown")
    assert_nil Monk::Auth.split(nil)
  end

  def test_own_session_bang_sets_cookies_for_the_new_session
    session = new_session
    app = Class.new(Monk::Base) do
      post("/auth/own") do |ctx|
        ctx.require_csrf!
        ctx.own_session! || ctx.halt(401)
        ctx.json(ok: true)
      end
    end

    status, headers, = app.call(cookie_post(session))

    assert_equal 200, status
    new_token = headers["set-cookie"].find { |c| c.start_with?("session_token=") }[/\Asession_token=([^;]+)/, 1]
    refute_equal session[:token], new_token
    assert_equal "a@b.com", Monk::Auth.verify(new_token)
    assert_equal "a@b.com", Monk::Auth.verify(session[:token]), "the old one is left to Safari"
  end

  def test_own_session_bang_is_nil_without_a_session
    app = Class.new(Monk::Base) do
      post("/auth/own") { |ctx| (ctx.own_session! || ctx.halt(401)) && ctx.json(ok: true) }
    end

    assert_equal 401, app.call(env_for("POST", "/auth/own")).first
  end

  def test_monk_head_names_the_route_when_auth_is_configured
    app = Class.new(Monk::Base) { get("/") { |ctx| ctx.monk_head } }

    _status, _headers, body = app.call(env_for("GET", "/"))

    assert_includes body.join, %(<meta name="monk-auth-own-url" content="/auth/own">)
  end

  private

  def new_session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com")[:token])

  def cookie_post(session)
    env = env_for("POST", "/auth/own")
    csrf = Monk::Auth.csrf_token_for(session[:token])
    env["HTTP_COOKIE"] = "session_token=#{session[:token]}; csrf_token=#{csrf}"
    env["HTTP_X_CSRF_TOKEN"] = csrf
    env
  end

  def rows_for(*sessions)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      sessions.map do |session|
        conn.exec_params("SELECT * FROM sessions WHERE token_hash = $1", [Monk::Auth.token_hash(session[:token])]).first
      end
    end
  end
end
