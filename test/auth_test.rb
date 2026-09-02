require_relative "test_helper"
require "digest"
require "securerandom"
require "monk/auth"

class AuthTest < Minitest::Test
  include PersistenceTestHelpers

  DB_NAME = :auth_test_db

  def setup
    Monk::Persistence::Pg.reset!
  end

  def teardown
    if postgres_available?
      begin
        Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_test_tables(conn) }
      rescue Monk::UnknownPersistenceError
      end
    end
    Monk::Persistence::Pg.reset!
  end

  def test_configure_stores_config_and_is_readable_back
    Monk::Auth.configure(db_name: DB_NAME, secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600)

    config = Monk::Auth.config

    assert_equal DB_NAME, config[:db_name]
    assert_equal "s3cr3t", config[:secret]
    assert_equal 600, config[:login_ttl]
    assert_equal 1_209_600, config[:session_ttl]
  end

  def test_configure_raises_a_precise_error_naming_a_missing_required_key
    error = assert_raises(Monk::MissingAuthConfigError) do
      Monk::Auth.configure(secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600)
    end

    assert_match(/db_name/, error.message)
  end

  def test_request_login_inserts_a_login_tokens_row_storing_only_the_hash
    setup_auth_tables

    raw = Monk::Auth.request_login("a@b.com")

    row = fetch_login_token(email: "a@b.com")
    assert_equal Digest::SHA256.hexdigest(raw), row["token_hash"]
    refute_includes row.values.join, raw
  end

  def test_request_login_twice_for_the_same_email_produces_two_distinct_valid_tokens
    setup_auth_tables

    first = Monk::Auth.request_login("a@b.com")
    second = Monk::Auth.request_login("a@b.com")

    refute_equal first, second
    rows = fetch_login_tokens(email: "a@b.com")
    assert_equal 2, rows.size
    assert_equal [nil, nil], rows.map { |r| r["used_at"] }
  end

  def test_redeem_on_a_fresh_token_returns_a_session_and_marks_the_login_token_used
    setup_auth_tables
    raw = Monk::Auth.request_login("a@b.com")

    session = Monk::Auth.redeem(raw)

    refute_nil session
    assert_kind_of String, session[:token]
    assert_equal "a@b.com", session[:subject]
    assert_kind_of Time, session[:expires_at]

    session_rows = fetch_sessions(subject: "a@b.com")
    assert_equal 1, session_rows.size
    assert_equal Digest::SHA256.hexdigest(session[:token]), session_rows.first["token_hash"]

    login_token_row = fetch_login_token(email: "a@b.com")
    refute_nil login_token_row["used_at"]
  end

  def test_redeem_returns_nil_for_an_unknown_token
    setup_auth_tables

    assert_nil Monk::Auth.redeem(SecureRandom.urlsafe_base64(32))
  end

  def test_redeem_returns_nil_for_a_malformed_or_empty_token
    setup_auth_tables

    assert_nil Monk::Auth.redeem("")
    assert_nil Monk::Auth.redeem(nil)
  end

  def test_redeem_returns_nil_for_an_expired_token
    setup_auth_tables
    raw = "expired-raw-token"
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params(
        "INSERT INTO login_tokens (email, token_hash, expires_at) VALUES ($1, $2, $3)",
        ["a@b.com", Digest::SHA256.hexdigest(raw), Time.now - 1],
      )
    end

    assert_nil Monk::Auth.redeem(raw)
  end

  private

  def setup_auth_tables
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      drop_test_tables(conn)
      conn.exec(<<~SQL)
        CREATE TABLE login_tokens (
          id BIGSERIAL PRIMARY KEY,
          email TEXT NOT NULL,
          token_hash TEXT NOT NULL UNIQUE,
          expires_at TIMESTAMPTZ NOT NULL,
          used_at TIMESTAMPTZ,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
      SQL
      conn.exec(<<~SQL)
        CREATE TABLE sessions (
          id BIGSERIAL PRIMARY KEY,
          subject TEXT NOT NULL,
          token_hash TEXT NOT NULL UNIQUE,
          expires_at TIMESTAMPTZ NOT NULL,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
      SQL
    end
    Monk::Auth.configure(db_name: DB_NAME, secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600)
  end

  def drop_test_tables(conn)
    conn.exec("DROP TABLE IF EXISTS sessions")
    conn.exec("DROP TABLE IF EXISTS login_tokens")
  end

  def fetch_login_token(email:)
    fetch_login_tokens(email: email).first
  end

  def fetch_login_tokens(email:)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("SELECT * FROM login_tokens WHERE email = $1", [email]).to_a
    end
  end

  def fetch_sessions(subject:)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("SELECT * FROM sessions WHERE subject = $1", [subject]).to_a
    end
  end
end
