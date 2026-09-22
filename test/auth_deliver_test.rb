require_relative "test_helper"
require "monk/auth"

class AuthDeliverTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthTestHelpers

  DB_NAME = :auth_deliver_test_db

  def setup
    Monk::Persistence::Pg.reset!
    setup_auth_tables(DB_NAME)
  end

  def teardown
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_auth_tables(conn) } if postgres_available?
    Monk::Persistence::Pg.reset!
    Monk::Auth.reset!
  end

  def test_deliver_link_calls_the_configured_deliver_with_email_link_and_token
    calls = []
    Monk::Auth.configure(
      db_name: DB_NAME, secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600,
      deliver: ->(email:, link:, token:) { calls << { email: email, link: link, token: token } },
    )

    Monk::Auth.deliver_link(email: "a@b.com", link: "https://app.example/auth/callback/abc", token: "abc")

    assert_equal [{ email: "a@b.com", link: "https://app.example/auth/callback/abc", token: "abc" }], calls
  end

  def test_deliver_link_prefers_the_configured_deliver_even_in_development
    calls = []
    with_settings do
      with_monk_env("development") do
        Monk::Auth.configure(
          db_name: DB_NAME, secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600,
          deliver: ->(email:, link:, token:) { calls << { email: email, link: link, token: token } },
        )

        out, = capture_io { Monk::Auth.deliver_link(email: "a@b.com", link: "http://x/y", token: "t") }

        assert_equal [{ email: "a@b.com", link: "http://x/y", token: "t" }], calls
        assert_empty out
      end
    end
  end

  def test_deliver_link_falls_back_to_log_dev_link_in_development_when_no_deliver_configured
    Monk::Auth.configure(db_name: DB_NAME, secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600)

    out, = with_log do
      with_settings do
        with_monk_env("development") do
          Monk::Log.freeze_registry!
          capture_io { Monk::Auth.deliver_link(email: "a@b.com", link: "http://x/y", token: "t") }
        end
      end
    end

    assert_includes out, "[dev] magic link for a@b.com: http://x/y"
  end

  def test_deliver_link_raises_outside_development_when_no_deliver_configured
    Monk::Auth.configure(db_name: DB_NAME, secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600)

    with_settings do
      with_monk_env("production") do
        error = assert_raises(Monk::MissingAuthDeliveryError) do
          Monk::Auth.deliver_link(email: "a@b.com", link: "http://x/y", token: "t")
        end

        assert_includes error.message, "a@b.com"
        assert_includes error.message, "deliver:"
      end
    end
  end
end
