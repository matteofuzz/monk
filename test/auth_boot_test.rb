require_relative "test_helper"
require "monk/auth"

class AuthBootTest < Minitest::Test
  def teardown
    Monk::Auth.reset!
  end

  # The actual regression this phase exists for: without a freeze hook,
  # Monk::Auth's @config (a plain, unfrozen Hash) can't be read from inside
  # a worker Ractor at all -- Ractor::IsolationError -- even though the
  # Auth module itself is always Ractor.shareable? (mirrors the identical
  # bug already fixed twice for Persistence -- docs/persistence-ractor-
  # connections.md "Phase 4 finding" and "Phase 5 finding").
  def test_app_boot_makes_auth_config_readable_from_a_real_worker_ractor
    Monk::Auth.configure(db_name: :some_db, secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600)

    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end
    app.freeze!

    result = Ractor.new { Monk::Auth.config[:secret] }.value

    assert_equal "s3cr3t", result
  end
end
