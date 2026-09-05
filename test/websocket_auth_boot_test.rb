require_relative "test_helper"
require "monk/auth"
require "monk/websocket"

class WebSocketAuthBootTest < Minitest::Test
  def teardown
    Monk::Auth.reset!
  end

  # The WS-specific version of auth_boot_test.rb's regression
  # (PLAN-WEBSOCKET.md Phase 5 step 20): a process that never touches
  # Monk::Base at all (Decision 1) still needs Monk::Auth's config
  # readable from a worker Ractor -- proving the freeze doesn't secretly
  # still depend on Base.
  def test_monk_freeze_makes_auth_config_readable_from_a_real_worker_ractor_without_base
    Monk::Auth.configure(db_name: :some_db, secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600)

    Monk.freeze!

    result = Ractor.new { Monk::Auth.config[:secret] }.value

    assert_equal "s3cr3t", result
  end
end
