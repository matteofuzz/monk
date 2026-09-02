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
    Monk::Auth.reset!
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

  def test_redeem_on_an_already_redeemed_token_returns_nil_and_creates_no_second_session
    setup_auth_tables
    raw = Monk::Auth.request_login("a@b.com")
    first = Monk::Auth.redeem(raw)

    second = Monk::Auth.redeem(raw)

    refute_nil first
    assert_nil second
    assert_equal 1, fetch_sessions(subject: "a@b.com").size
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

  def test_verify_returns_the_subject_for_a_valid_session_token
    setup_auth_tables
    raw = Monk::Auth.request_login("a@b.com")
    session = Monk::Auth.redeem(raw)

    assert_equal "a@b.com", Monk::Auth.verify(session[:token])
  end

  def test_verify_returns_nil_for_an_unknown_token
    setup_auth_tables

    assert_nil Monk::Auth.verify(SecureRandom.urlsafe_base64(32))
  end

  def test_verify_returns_nil_for_an_expired_session
    setup_auth_tables
    raw = "expired-session-token"
    insert_session(subject: "a@b.com", raw: raw, expires_at: Time.now - 1)

    assert_nil Monk::Auth.verify(raw)
  end

  def test_verify_returns_nil_for_a_revoked_session
    setup_auth_tables
    raw = "revoked-session-token"
    insert_session(subject: "a@b.com", raw: raw, expires_at: Time.now + 3600, revoked_at: Time.now)

    assert_nil Monk::Auth.verify(raw)
  end

  def test_revoke_sets_revoked_at_so_a_subsequent_verify_returns_nil
    setup_auth_tables
    raw = Monk::Auth.request_login("a@b.com")
    session = Monk::Auth.redeem(raw)

    result = Monk::Auth.revoke(session[:token])

    assert_equal true, result
    assert_nil Monk::Auth.verify(session[:token])
  end

  def test_revoke_returns_false_for_an_unknown_token
    setup_auth_tables

    refute Monk::Auth.revoke(SecureRandom.urlsafe_base64(32))
  end

  def test_revoke_all_revokes_every_live_session_for_a_subject_and_returns_the_count
    setup_auth_tables
    session_a1 = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    session_a2 = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    session_b = Monk::Auth.redeem(Monk::Auth.request_login("b@c.com"))

    count = Monk::Auth.revoke_all("a@b.com")

    assert_equal 2, count
    assert_nil Monk::Auth.verify(session_a1[:token])
    assert_nil Monk::Auth.verify(session_a2[:token])
    assert_equal "b@c.com", Monk::Auth.verify(session_b[:token])
  end

  def test_calling_a_method_before_configure_raises_a_precise_error
    Monk::Auth.reset!

    error = assert_raises(Monk::AuthNotConfiguredError) { Monk::Auth.request_login("a@b.com") }

    assert_match(/configure/, error.message)
  end

  def test_sweep_bang_deletes_expired_rows_and_returns_the_counts
    setup_auth_tables
    live_raw = Monk::Auth.request_login("a@b.com")
    insert_login_token(email: "old@b.com", raw: "expired-login-token", expires_at: Time.now - 1)
    live_session = Monk::Auth.redeem(Monk::Auth.request_login("b@c.com"))
    insert_session(subject: "old@c.com", raw: "expired-session-token", expires_at: Time.now - 1)

    counts = Monk::Auth.sweep!

    assert_equal({ login_tokens: 1, sessions: 1 }, counts)
    refute_nil Monk::Auth.redeem(live_raw)
    assert_equal "b@c.com", Monk::Auth.verify(live_session[:token])
  end

  private

  def insert_login_token(email:, raw:, expires_at:)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params(
        "INSERT INTO login_tokens (email, token_hash, expires_at) VALUES ($1, $2, $3)",
        [email, Digest::SHA256.hexdigest(raw), expires_at],
      )
    end
  end

  def insert_session(subject:, raw:, expires_at:, revoked_at: nil)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params(
        "INSERT INTO sessions (subject, token_hash, expires_at, revoked_at) VALUES ($1, $2, $3, $4)",
        [subject, Digest::SHA256.hexdigest(raw), expires_at, revoked_at],
      )
    end
  end

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
          revoked_at TIMESTAMPTZ,
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
