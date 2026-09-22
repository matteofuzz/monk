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

  # A deliver: proc built where self is shareable (a module constant, same
  # requirement as Monk::Live.authorize blocks) survives freeze and is
  # callable from inside a real worker Ractor.
  def test_a_module_scoped_deliver_proc_is_readable_and_callable_from_a_real_worker_ractor
    Monk::Auth.configure(
      db_name: :some_db, secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600,
      deliver: AuthBootTestMailer::DELIVER,
    )

    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end
    app.freeze!

    result = Ractor.new do
      Monk::Auth.config[:deliver].call(email: "a@b.com", link: "http://x/y", token: "t")
    end.value

    assert_equal "a@b.com http://x/y t", result
  end

  # The same constraint routes already enforce (base.rb's UnshareableRouteError):
  # a deliver: proc that captures non-shareable state -- self at a script's
  # top level, here -- fails freeze! loudly, not on the first real delivery.
  def test_an_unshareable_deliver_proc_raises_at_boot
    Monk::Auth.configure(
      db_name: :some_db, secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600,
      deliver: ->(email:, link:, token:) { "#{email} #{link} #{token}" },
    )

    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    error = assert_raises(Monk::UnshareableBlockError) { app.freeze! }
    assert_includes error.message, "deliver:"
  end
end

module AuthBootTestMailer
  DELIVER = ->(email:, link:, token:) { "#{email} #{link} #{token}" }
end
