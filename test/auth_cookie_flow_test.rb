require_relative "test_helper"
require "json"
require "monk/auth"

# End-to-end over App.call(env), per PLAN-AUTH.md Phase 9 step 36: the
# browser/cookie path, exercised exactly as docs/auth-sessions.md's
# "Proposed API" describes it, distinct from the Bearer round trip already
# proven in auth_ractor_integration_test.rb.
class AuthCookieFlowTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthTestHelpers

  DB_NAME = :auth_cookie_flow_test_db

  def setup
    Monk::Persistence::Pg.reset!
  end

  def teardown
    if postgres_available?
      begin
        Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_auth_tables(conn) }
      rescue Monk::UnknownPersistenceError
      end
    end
    Monk::Persistence::Pg.reset!
    Monk::Auth.reset!
  end

  def build_app
    Class.new(Monk::Base) do
      post("/auth/request") do |ctx|
        token = Monk::Auth.request_login(ctx.params[:email], redirect_to: ctx.params[:redirect_to])
        ctx.json(token: token) # test-only: a real app emails this, never echoes it
      end

      get("/auth/callback/:token") do |ctx|
        session = Monk::Auth.redeem(ctx.params[:token])
        ctx.halt(401) unless session

        if session[:redirect_to]
          ctx.set_session_cookie(session)
          ctx.redirect(session[:redirect_to])
        else
          ctx.json(token: session[:token], expires_at: session[:expires_at])
        end
      end

      get("/me") do |ctx|
        ctx.json(subject: ctx.require_user!)
      end

      post("/orders") do |ctx|
        ctx.require_user!
        ctx.require_csrf!
        ctx.json(ok: true)
      end

      delete("/auth/session") do |ctx|
        ctx.require_csrf!
        Monk::Auth.revoke(ctx.send(:session_cookie_token))
        ctx.clear_session_cookie
        ctx.json(ok: true)
      end
    end
  end

  def test_full_cookie_and_csrf_round_trip
    setup_auth_tables(DB_NAME)
    app = build_app

    request_env = env_for("POST", "/auth/request")
    request_env["CONTENT_TYPE"] = "application/json"
    request_env["rack.input"] = StringIO.new(JSON.generate(email: "a@b.com", redirect_to: "/dashboard"))
    _status, _headers, request_body = app.call(request_env)
    raw_token = JSON.parse(request_body.join)["token"]

    status, headers, = app.call(env_for("GET", "/auth/callback/#{raw_token}"))
    assert_equal 302, status
    assert_equal "/dashboard", headers["location"]
    refute_includes headers["location"], raw_token
    cookies = headers["set-cookie"]
    assert_equal 2, cookies.size
    session_cookie_header = cookies.find { |c| c.start_with?("session_token=") }.split(";").first
    csrf_token = cookies.find { |c| c.start_with?("csrf_token=") }.split(";").first.split("=", 2).last

    me_env = env_for("GET", "/me")
    me_env["HTTP_COOKIE"] = session_cookie_header
    me_status, _headers, me_body = app.call(me_env)
    assert_equal 200, me_status
    assert_equal "a@b.com", JSON.parse(me_body.join)["subject"]

    orders_without_csrf = env_for("POST", "/orders")
    orders_without_csrf["HTTP_COOKIE"] = session_cookie_header
    assert_equal 403, app.call(orders_without_csrf).first

    orders_with_csrf = env_for("POST", "/orders")
    orders_with_csrf["HTTP_COOKIE"] = session_cookie_header
    orders_with_csrf["HTTP_X_CSRF_TOKEN"] = csrf_token
    assert_equal 200, app.call(orders_with_csrf).first

    logout_env = env_for("DELETE", "/auth/session")
    logout_env["HTTP_COOKIE"] = session_cookie_header
    logout_env["HTTP_X_CSRF_TOKEN"] = csrf_token
    logout_status, logout_headers, = app.call(logout_env)
    assert_equal 200, logout_status
    logout_cookies = logout_headers["set-cookie"]
    assert(logout_cookies.all? { |c| c.include?("Max-Age=0") })

    me_after_logout_env = env_for("GET", "/me")
    me_after_logout_env["HTTP_COOKIE"] = session_cookie_header
    assert_equal 401, app.call(me_after_logout_env).first
  end
end
