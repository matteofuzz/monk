require_relative "test_helper"
require "securerandom"
require "openssl"
require "json"
require "monk/auth"

class AuthHelpersTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthTestHelpers

  DB_NAME = :auth_helpers_test_db

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

  def test_require_user_bang_returns_401_when_the_authorization_header_is_missing
    setup_auth_tables(DB_NAME)
    app = Class.new(Monk::Base) do
      get("/me") { |ctx| ctx.require_user! }
    end

    status, = app.call(env_for("GET", "/me"))

    assert_equal 401, status
  end

  def test_require_user_bang_returns_401_for_a_malformed_authorization_header
    setup_auth_tables(DB_NAME)
    app = Class.new(Monk::Base) do
      get("/me") { |ctx| ctx.require_user! }
    end

    no_bearer_prefix = env_for("GET", "/me")
    no_bearer_prefix["HTTP_AUTHORIZATION"] = "sometoken"
    empty_token = env_for("GET", "/me")
    empty_token["HTTP_AUTHORIZATION"] = "Bearer "

    assert_equal 401, app.call(no_bearer_prefix).first
    assert_equal 401, app.call(empty_token).first
  end

  def test_require_user_bang_returns_401_for_an_expired_revoked_or_unknown_token
    setup_auth_tables(DB_NAME)
    app = Class.new(Monk::Base) do
      get("/me") { |ctx| ctx.require_user! }
    end
    valid_session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    Monk::Auth.revoke(valid_session[:token])

    unknown = env_for("GET", "/me")
    unknown["HTTP_AUTHORIZATION"] = "Bearer #{SecureRandom.urlsafe_base64(32)}"
    revoked = env_for("GET", "/me")
    revoked["HTTP_AUTHORIZATION"] = "Bearer #{valid_session[:token]}"

    assert_equal 401, app.call(unknown).first
    assert_equal 401, app.call(revoked).first
  end

  def test_require_user_bang_returns_the_subject_for_a_valid_token
    setup_auth_tables(DB_NAME)
    app = Class.new(Monk::Base) do
      get("/me") { |ctx| ctx.require_user! }
    end
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    request_env = env_for("GET", "/me")
    request_env["HTTP_AUTHORIZATION"] = "Bearer #{session[:token]}"

    status, _headers, body = app.call(request_env)

    assert_equal 200, status
    assert_equal "a@b.com", body.join
  end

  def test_set_session_cookie_sets_an_httponly_session_cookie_and_a_readable_csrf_cookie
    setup_auth_tables(DB_NAME)
    app = Class.new(Monk::Base) do
      get("/x") do |ctx|
        session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
        ctx.set_session_cookie(session)
        ctx.json(ok: true)
      end
    end

    _status, headers, = app.call(env_for("GET", "/x"))

    cookies = headers["set-cookie"]
    assert_equal 2, cookies.size
    session_cookie = cookies.find { |c| c.start_with?("session_token=") }
    csrf_cookie = cookies.find { |c| c.start_with?("csrf_token=") }
    refute_nil session_cookie
    refute_nil csrf_cookie
    assert_includes session_cookie, "HttpOnly"
    assert_includes session_cookie, "Secure"
    assert_includes session_cookie, "SameSite=Lax"
    assert_includes session_cookie, "Path=/"
    refute_includes csrf_cookie, "HttpOnly"
    assert_includes csrf_cookie, "Secure"
  end

  def test_set_session_cookie_computes_the_csrf_cookie_as_hmac_sha256_of_the_session_token
    setup_auth_tables(DB_NAME)
    app = Class.new(Monk::Base) do
      get("/x") do |ctx|
        session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
        ctx.set_session_cookie(session)
        ctx.json(token: session[:token])
      end
    end

    _status, headers, body = app.call(env_for("GET", "/x"))

    session_token = JSON.parse(body.join)["token"]
    expected = OpenSSL::HMAC.hexdigest("SHA256", "s3cr3t", session_token)
    csrf_cookie = headers["set-cookie"].find { |c| c.start_with?("csrf_token=") }
    assert_equal "csrf_token=#{expected}", csrf_cookie.split(";").first
  end

  def test_current_subject_falls_back_to_the_session_cookie_when_authorization_is_absent
    setup_auth_tables(DB_NAME)
    app = Class.new(Monk::Base) do
      get("/me") { |ctx| ctx.require_user! }
    end
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    request_env = env_for("GET", "/me")
    request_env["HTTP_COOKIE"] = "session_token=#{session[:token]}"

    status, _headers, body = app.call(request_env)

    assert_equal 200, status
    assert_equal "a@b.com", body.join
  end

  def test_current_subject_prefers_authorization_over_the_session_cookie_when_both_are_present
    setup_auth_tables(DB_NAME)
    app = Class.new(Monk::Base) do
      get("/me") { |ctx| ctx.require_user! }
    end
    bearer_session = Monk::Auth.redeem(Monk::Auth.request_login("bearer@b.com"))
    cookie_session = Monk::Auth.redeem(Monk::Auth.request_login("cookie@b.com"))
    request_env = env_for("GET", "/me")
    request_env["HTTP_AUTHORIZATION"] = "Bearer #{bearer_session[:token]}"
    request_env["HTTP_COOKIE"] = "session_token=#{cookie_session[:token]}"

    _status, _headers, body = app.call(request_env)

    assert_equal "bearer@b.com", body.join
  end

  def test_require_csrf_bang_guards_post_put_patch_and_delete_routes_authenticated_via_cookie
    setup_auth_tables(DB_NAME)
    app = Class.new(Monk::Base) do
      %i[post put patch delete].each do |verb|
        send(verb, "/x") do |ctx|
          ctx.require_user!
          ctx.require_csrf!
          ctx.json(ok: true)
        end
      end
    end
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    csrf_token = Monk::Auth.csrf_token_for(session[:token])

    %w[POST PUT PATCH DELETE].each do |verb|
      without_header = env_for(verb, "/x")
      without_header["HTTP_COOKIE"] = "session_token=#{session[:token]}"

      with_header = env_for(verb, "/x")
      with_header["HTTP_COOKIE"] = "session_token=#{session[:token]}"
      with_header["HTTP_X_CSRF_TOKEN"] = csrf_token

      assert_equal 403, app.call(without_header).first, "#{verb} without X-CSRF-Token should be 403"
      assert_equal 200, app.call(with_header).first, "#{verb} with a valid X-CSRF-Token should be 200"
    end
  end

  def test_require_csrf_bang_returns_403_for_a_wrong_csrf_token
    setup_auth_tables(DB_NAME)
    app = Class.new(Monk::Base) do
      post("/x") do |ctx|
        ctx.require_user!
        ctx.require_csrf!
        ctx.json(ok: true)
      end
    end
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    request_env = env_for("POST", "/x")
    request_env["HTTP_COOKIE"] = "session_token=#{session[:token]}"
    request_env["HTTP_X_CSRF_TOKEN"] = "wrong-token"

    status, = app.call(request_env)

    assert_equal 403, status
  end

  def test_require_csrf_bang_is_a_no_op_for_bearer_authenticated_requests
    setup_auth_tables(DB_NAME)
    app = Class.new(Monk::Base) do
      post("/x") do |ctx|
        ctx.require_user!
        ctx.require_csrf!
        ctx.json(ok: true)
      end
    end
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    request_env = env_for("POST", "/x")
    request_env["HTTP_AUTHORIZATION"] = "Bearer #{session[:token]}"

    status, = app.call(request_env)

    assert_equal 200, status
  end

  def test_clear_session_cookie_resends_both_cookies_with_an_already_expired_max_age
    setup_auth_tables(DB_NAME)
    app = Class.new(Monk::Base) do
      delete("/auth/session") do |ctx|
        ctx.clear_session_cookie
        ctx.json(ok: true)
      end
    end

    _status, headers, = app.call(env_for("DELETE", "/auth/session"))

    cookies = headers["set-cookie"]
    assert_equal 2, cookies.size
    session_cookie = cookies.find { |c| c.start_with?("session_token=") }
    csrf_cookie = cookies.find { |c| c.start_with?("csrf_token=") }
    assert_includes session_cookie, "Max-Age=0"
    assert_includes csrf_cookie, "Max-Age=0"
  end

  def test_current_subject_is_nil_on_an_unguarded_route_and_still_returns_200
    setup_auth_tables(DB_NAME)
    app = Class.new(Monk::Base) do
      get("/x") { |ctx| ctx.current_subject.inspect }
    end

    status, _headers, body = app.call(env_for("GET", "/x"))

    assert_equal 200, status
    assert_equal "nil", body.join
  end
end
