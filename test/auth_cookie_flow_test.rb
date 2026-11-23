require_relative "test_helper"
require "json"
require "monk/auth"

# End-to-end over App.call(env), per docs/history/plan-auth.md Phase 9 step 36: the
# browser/cookie path, exercised exactly as docs/design/auth-sessions.md's
# "Proposed API" describes it, distinct from the Bearer round trip already
# proven in auth_ractor_integration_test.rb.
class AuthCookieFlowTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthDatabaseTest

  DB_NAME = :auth_cookie_flow_test_db

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

      get("/form") { |ctx| ctx.csrf_field }

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

  # A plain HTML form: the page writes the token with csrf_field, the
  # browser posts it back as a field, _method=delete reaches the DELETE
  # route.
  def test_a_plain_form_posts_the_csrf_token_as_a_field
    setup_auth_tables(DB_NAME)
    app = build_app
    session_cookie_header = log_in(app)

    assert_equal "", app.call(env_for("GET", "/form"))[2].join

    form_env = env_for("GET", "/form")
    form_env["HTTP_COOKIE"] = session_cookie_header
    field = app.call(form_env)[2].join
    token = field[/\A<input type="hidden" name="csrf_token" value="(\h{64})">\z/, 1]
    refute_nil token, field

    wrong = form_post(session_cookie_header, "_method=delete&csrf_token=#{"0" * 64}")
    nested = form_post(session_cookie_header, "_method=delete&csrf_token[x]=#{token}")
    right = form_post(session_cookie_header, "_method=delete&csrf_token=#{token}")

    assert_equal 403, app.call(wrong).first
    assert_equal 403, app.call(nested).first
    assert_equal 200, app.call(right).first
  end

  # AUTH_SECRET changed (a backup restored with a new one): the session
  # still verifies, the csrf_token cookie signed with the old secret
  # doesn't. The next signed-in request mends it, and so does a 403.
  def test_a_csrf_cookie_from_an_old_secret_is_reissued
    setup_auth_tables(DB_NAME)
    app = build_app
    session_cookie = log_in(app)
    old_token = Monk::Auth.csrf_token_for(session_cookie.split("=", 2).last)
    Monk::Auth.configure(db_name: DB_NAME, secret: "rotated", login_ttl: 600, session_ttl: 1_209_600,
      redirect_allowlist: ["/dashboard"],)
    stale = "#{session_cookie}; csrf_token=#{old_token}"

    status, headers, = app.call(orders(stale, old_token))
    assert_equal 403, status
    fresh = csrf_cookie_value(headers)
    refute_nil fresh, "the 403 carries a fresh csrf_token cookie"
    refute_equal old_token, fresh
    assert_match(/Max-Age=1209\d{3}/, headers["set-cookie"].find { |c| c.start_with?("csrf_token=") })

    assert_equal 200, app.call(orders("#{session_cookie}; csrf_token=#{fresh}", fresh)).first
    assert_equal fresh, csrf_cookie_value(app.call(me(stale))[1]), "a page load mends it too"
  end

  def test_a_matching_csrf_cookie_is_left_alone_and_a_missing_one_is_set
    setup_auth_tables(DB_NAME)
    app = build_app
    session_cookie = log_in(app)
    token = Monk::Auth.csrf_token_for(session_cookie.split("=", 2).last)

    assert_nil app.call(me("#{session_cookie}; csrf_token=#{token}"))[1]["set-cookie"]
    assert_equal token, csrf_cookie_value(app.call(me(session_cookie))[1])
  end

  def test_no_csrf_cookie_without_a_valid_session
    setup_auth_tables(DB_NAME)
    app = build_app

    status, headers, = app.call(me("session_token=nope; csrf_token=stale"))

    assert_equal 401, status
    assert_nil headers["set-cookie"]
  end

  private

  def me(cookie)
    env_for("GET", "/me").merge("HTTP_COOKIE" => cookie)
  end

  def orders(cookie, token)
    env_for("POST", "/orders").merge("HTTP_COOKIE" => cookie, "HTTP_X_CSRF_TOKEN" => token)
  end

  def csrf_cookie_value(headers)
    Array(headers["set-cookie"]).find { |c| c.start_with?("csrf_token=") }.to_s.split(";").first.to_s.split("=", 2).last
  end

  def log_in(app)
    request_env = env_for("POST", "/auth/request")
    request_env["CONTENT_TYPE"] = "application/json"
    request_env["rack.input"] = StringIO.new(JSON.generate(email: "a@b.com", redirect_to: "/dashboard"))
    raw_token = JSON.parse(app.call(request_env)[2].join)["token"]
    cookies = app.call(env_for("GET", "/auth/callback/#{raw_token}"))[1]["set-cookie"]
    cookies.find { |c| c.start_with?("session_token=") }.split(";").first
  end

  def form_post(cookie, body)
    env = env_for("POST", "/auth/session")
    env["HTTP_COOKIE"] = cookie
    env["CONTENT_TYPE"] = "application/x-www-form-urlencoded"
    env["rack.input"] = StringIO.new(body)
    env
  end
end
