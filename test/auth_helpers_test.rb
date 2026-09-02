require_relative "test_helper"
require "securerandom"
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
