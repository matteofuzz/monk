require_relative "test_helper"
require "monk/auth"

# The login-email rate limit (docs/plan-auth-housekeeping.md decisions 5
# and 8, Phase 2): at most one login request per address per
# login_request_interval, recorded in login_requests by one upsert.
class AuthLoginRequestsTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthTestHelpers

  DB_NAME = :auth_login_requests_test_db

  def setup
    Monk::Persistence::Pg.reset!
    Monk::Auth.reset!
  end

  def teardown
    if postgres_available?
      begin
        Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_auth_tables(conn) }
      rescue Monk::UnknownPersistenceError
        nil # a configure-only test never registered the database
      end
    end
    Monk::Persistence::Pg.reset!
    Monk::Auth.reset!
  end

  # --- configure ---

  def test_the_interval_defaults_to_a_minute
    Monk::Auth.configure(db_name: DB_NAME, secret: "s", login_ttl: 600, session_ttl: 3600)

    assert_equal 60, Monk::Auth.config[:login_request_interval]
  end

  def test_the_interval_can_be_set
    Monk::Auth.configure(db_name: DB_NAME, secret: "s", login_ttl: 600, session_ttl: 3600, login_request_interval: 300)

    assert_equal 300, Monk::Auth.config[:login_request_interval]
  end

  def test_the_interval_is_a_positive_integer_of_seconds
    [0, -1, 1.5, "60", nil].each do |interval|
      error = assert_raises(Monk::InvalidAuthConfigError, interval.inspect) do
        Monk::Auth.configure(
          db_name: DB_NAME, secret: "s", login_ttl: 600, session_ttl: 3600, login_request_interval: interval,
        )
      end
      assert_match(/login_request_interval/, error.message)
    end
  end

  # --- allow_login_request? ---

  def test_the_first_request_for_an_address_is_allowed_and_a_second_is_not
    setup_auth_tables(DB_NAME)

    assert Monk::Auth.allow_login_request?("ann@example.test")
    refute Monk::Auth.allow_login_request?("ann@example.test")
  end

  def test_allowed_again_once_the_interval_has_passed
    setup_auth_tables(DB_NAME)
    Monk::Auth.allow_login_request?("ann@example.test")

    requested_seconds_ago("ann@example.test", 61)

    assert Monk::Auth.allow_login_request?("ann@example.test")
  end

  def test_still_refused_just_inside_the_interval
    setup_auth_tables(DB_NAME)
    Monk::Auth.allow_login_request?("ann@example.test")

    requested_seconds_ago("ann@example.test", 55)

    refute Monk::Auth.allow_login_request?("ann@example.test")
  end

  # A refused request leaves requested_at alone, so retrying doesn't push
  # the next allowed one further away.
  def test_a_refused_request_doesnt_restart_the_interval
    setup_auth_tables(DB_NAME)
    Monk::Auth.allow_login_request?("ann@example.test")
    requested_seconds_ago("ann@example.test", 50)

    refute Monk::Auth.allow_login_request?("ann@example.test")

    assert_in_delta 50, seconds_since_requested("ann@example.test"), 2
  end

  def test_addresses_are_limited_separately
    setup_auth_tables(DB_NAME)
    Monk::Auth.allow_login_request?("ann@example.test")

    assert Monk::Auth.allow_login_request?("bob@example.test")
  end

  # Ann@... and ann@... reach the same inbox, so they share a limit.
  def test_case_and_surrounding_spaces_dont_get_around_the_limit
    setup_auth_tables(DB_NAME)
    Monk::Auth.allow_login_request?("ann@example.test")

    refute Monk::Auth.allow_login_request?("  Ann@Example.TEST ")
    assert_equal ["ann@example.test"], login_request_emails
  end

  def test_the_configured_interval_applies
    setup_auth_tables(DB_NAME)
    Monk::Auth.configure(**Monk::Auth.config, login_request_interval: 300)
    Monk::Auth.allow_login_request?("ann@example.test")

    requested_seconds_ago("ann@example.test", 120)

    refute Monk::Auth.allow_login_request?("ann@example.test")
  end

  def test_an_address_must_be_a_non_blank_string
    setup_auth_tables(DB_NAME)

    [nil, "", "   ", 42].each do |email|
      assert_raises(ArgumentError, email.inspect) { Monk::Auth.allow_login_request?(email) }
    end
  end

  def test_before_configure_it_raises
    assert_raises(Monk::AuthNotConfiguredError) { Monk::Auth.allow_login_request?("ann@example.test") }
  end

  # One statement: requests racing for one address, each on its own
  # connection (one per Ractor), let exactly one through.
  def test_racing_requests_for_one_address_let_one_through
    setup_auth_tables(DB_NAME)
    Monk.freeze!

    ractors = Array.new(8) { Ractor.new { Monk::Auth.allow_login_request?("ann@example.test") } }

    assert_equal [true], ractors.map(&:value).select(&:itself)
  end

  # --- clear_login_requests! ---

  def test_clear_login_requests_empties_the_table
    setup_auth_tables(DB_NAME)
    Monk::Auth.allow_login_request?("ann@example.test")

    Monk::Auth.clear_login_requests!

    assert Monk::Auth.allow_login_request?("ann@example.test")
  end

  def test_clear_login_requests_refuses_outside_the_test_environment
    setup_auth_tables(DB_NAME)
    Monk::Auth.allow_login_request?("ann@example.test")

    with_settings do
      with_env("MONK_ENV", "production") do
        error = assert_raises(Monk::ClearLoginRequestsOutsideTestsError) { Monk::Auth.clear_login_requests! }
        assert_match(/MONK_ENV=test/, error.message)
      end
    end
    assert_equal ["ann@example.test"], login_request_emails
  end

  private

  def requested_seconds_ago(email, seconds)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params(
        "UPDATE login_requests SET requested_at = now() - $2::int * interval '1 second' WHERE email = $1",
        [email, seconds],
      )
    end
  end

  def seconds_since_requested(email)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params(
        "SELECT extract(epoch FROM now() - requested_at)::float8 FROM login_requests WHERE email = $1", [email],
      ).getvalue(0, 0)
    end
  end

  def login_request_emails
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec("SELECT email FROM login_requests ORDER BY email").map { |row| row["email"] }
    end
  end
end
