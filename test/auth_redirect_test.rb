require_relative "test_helper"
require "monk/auth"

# 0.28: redirect_allowlist patterns, allowed_redirect?, redirect_for, and
# what deliver: is told about a login (docs/plan-onboarding.md, step 1).
class AuthRedirectTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthDatabaseTest

  DB_NAME = :auth_redirect_test_db

  def configure(allowlist, deliver: nil)
    Monk::Auth.configure(
      db_name: DB_NAME, secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600,
      redirect_allowlist: allowlist, deliver: deliver,
    )
  end

  def test_a_string_entry_allows_that_exact_path
    configure(["/dashboard"])

    assert Monk::Auth.allowed_redirect?("/dashboard")
    refute Monk::Auth.allowed_redirect?("/dashboard/x")
    refute Monk::Auth.allowed_redirect?("/other")
  end

  def test_a_regexp_entry_must_match_the_whole_path
    configure([%r{/invite/[a-z0-9]+}])

    assert Monk::Auth.allowed_redirect?("/invite/abc123")
    refute Monk::Auth.allowed_redirect?("/invite/abc123/../../admin")
    refute Monk::Auth.allowed_redirect?("/x/invite/abc")
    refute Monk::Auth.allowed_redirect?("/invite/")
  end

  def test_a_regexp_with_alternatives_matches_whole_through_any_of_them
    configure([%r{/a|/ab}])

    assert Monk::Auth.allowed_redirect?("/ab")
    refute Monk::Auth.allowed_redirect?("/abc")
  end

  def test_a_query_string_after_an_allowed_path_is_allowed
    configure(["/dashboard", %r{/invite/[a-z0-9]+}])

    assert Monk::Auth.allowed_redirect?("/dashboard?tab=1")
    assert Monk::Auth.allowed_redirect?("/invite/abc?expired=1")
  end

  def test_a_redirect_must_start_with_a_single_slash_whatever_the_list_says
    configure([/.*/, "//evil.example", "/\\evil.example"])

    assert Monk::Auth.allowed_redirect?("/anything")
    refute Monk::Auth.allowed_redirect?("//evil.example")
    refute Monk::Auth.allowed_redirect?("/\\evil.example")
    refute Monk::Auth.allowed_redirect?("https://evil.example")
    refute Monk::Auth.allowed_redirect?("")
    refute Monk::Auth.allowed_redirect?(nil)
  end

  def test_configure_refuses_an_entry_that_is_neither_a_string_nor_a_regexp
    error = assert_raises(Monk::InvalidAuthConfigError) { configure([:dashboard]) }

    assert_includes error.message, "redirect_allowlist"
  end

  def test_the_allowlist_with_a_regexp_is_shareable_after_freeze
    configure([%r{/invite/\w+}])

    Monk::Auth.freeze_registry!

    assert Ractor.shareable?(Monk::Auth.config)
  end

  def test_request_login_accepts_a_path_matching_a_pattern
    setup_auth_tables(DB_NAME)
    configure([%r{/invite/\w+}])

    raw = Monk::Auth.request_login("a@b.com", redirect_to: "/invite/abc")

    assert_equal "/invite/abc", Monk::Auth.redirect_for(raw)
  end

  def test_request_login_refuses_a_path_no_entry_matches
    setup_auth_tables(DB_NAME)
    configure([%r{/invite/\w+}])

    assert_raises(Monk::InvalidRedirectError) { Monk::Auth.request_login("a@b.com", redirect_to: "/admin") }
  end

  def test_redirect_for_answers_for_an_expired_or_used_token_and_nil_for_an_unknown_one
    setup_auth_tables(DB_NAME)
    configure(["/dashboard"])
    used = Monk::Auth.request_login("a@b.com", redirect_to: "/dashboard")
    Monk::Auth.redeem(used)
    expired = "expired-raw-token"
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params(
        "INSERT INTO login_tokens (email, token_hash, redirect_to, expires_at) VALUES ($1, $2, $3, $4)",
        ["a@b.com", Digest::SHA256.hexdigest(expired), "/dashboard", Time.now - 1],
      )
    end

    assert_equal "/dashboard", Monk::Auth.redirect_for(used)
    assert_equal "/dashboard", Monk::Auth.redirect_for(expired)
    assert_nil Monk::Auth.redirect_for("unknown")
    assert_nil Monk::Auth.redirect_for("")
    assert_nil Monk::Auth.redirect_for(nil)
  end

  def test_deliver_link_passes_redirect_to_and_code_to_deliver
    calls = []
    configure([], deliver: ->(**kwargs) { calls << kwargs })

    Monk::Auth.deliver_link(email: "a@b.com", link: "http://x/y", token: "t", redirect_to: "/invite/abc")

    assert_equal [{ email: "a@b.com", link: "http://x/y", token: "t", redirect_to: "/invite/abc", code: nil }], calls
  end
end
