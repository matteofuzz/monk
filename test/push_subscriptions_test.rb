require_relative "test_helper"
require "monk/push"

# Monk::Push's subscriptions (docs/plan-pwa-push.md, B3), on real
# Postgres: each belongs to the auth session it was made in, and counts
# only while that session is neither revoked nor expired.
class PushSubscriptionsTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthTestHelpers
  include PushTestHelpers

  DB_NAME = :push_subscriptions_test_db

  def setup
    Monk::Persistence::Pg.reset!
    setup_push_tables(DB_NAME)
    pair = Monk::Push::Keys.generate
    Monk::Push.configure(db_name: DB_NAME, contact: "mailto:ops@shop.test", **pair)
    @ann = sign_in("ann@shop.test")
  end

  def teardown
    if postgres_available?
      Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
        drop_push_tables(conn)
        drop_auth_tables(conn)
      end
    end
    Monk::Push.reset!
    Monk::Auth.reset!
    Monk::Persistence::Pg.reset!
  end

  def test_a_signed_in_browser_subscribes
    subscription = browser_subscription

    row = Monk::Push.subscribe(session_token: @ann[:token], subscription: subscription, user_agent: "Firefox")

    assert_equal "ann@shop.test", row[:subject]
    stored = Monk::Push.subscriptions("ann@shop.test")
    assert_equal([subscription["endpoint"]], stored.map { |sub| sub[:endpoint] })
    assert_equal subscription["keys"].values_at("p256dh", "auth"), stored.first.values_at(:p256dh, :auth)
    assert Monk::Push.subscribed?("ann@shop.test")
  end

  def test_no_session_no_subscription
    assert_nil Monk::Push.subscribe(session_token: "not-a-session", subscription: browser_subscription)
    assert_nil Monk::Push.subscribe(session_token: nil, subscription: browser_subscription)
    assert_nil Monk::Push.subscribe(session_token: "", subscription: browser_subscription)
    assert_empty rows
  end

  # Every page load re-sends the subscription: one row per browser, its
  # keys kept current, and a shared device follows whoever signed in last.
  def test_the_same_browser_again_updates_its_one_row_and_follows_the_session
    first = browser_subscription
    Monk::Push.subscribe(session_token: @ann[:token], subscription: first)
    rotated = browser_subscription(endpoint: first["endpoint"])
    Monk::Push.subscribe(session_token: @ann[:token], subscription: rotated)

    assert_equal 1, rows.size
    assert_equal rotated["keys"]["p256dh"], Monk::Push.subscriptions("ann@shop.test").first[:p256dh]

    bob = sign_in("bob@shop.test")
    Monk::Push.subscribe(session_token: bob[:token], subscription: rotated)

    assert_empty Monk::Push.subscriptions("ann@shop.test")
    assert_equal 1, Monk::Push.subscriptions("bob@shop.test").size
  end

  def test_a_revoked_session_stops_its_subscriptions_at_once
    Monk::Push.subscribe(session_token: @ann[:token], subscription: browser_subscription)
    other_device = sign_in("ann@shop.test")
    Monk::Push.subscribe(session_token: other_device[:token], subscription: browser_subscription)

    Monk::Auth.revoke(@ann[:token])

    assert_equal 1, Monk::Push.subscriptions("ann@shop.test").size, "the other device still counts"
    Monk::Auth.revoke_all("ann@shop.test")
    assert_empty Monk::Push.subscriptions("ann@shop.test")
    refute Monk::Push.subscribed?("ann@shop.test")
    assert_nil Monk::Push.subscribe(session_token: @ann[:token], subscription: browser_subscription)
  end

  def test_an_expired_session_stops_counting_and_auth_sweep_takes_its_rows
    Monk::Push.subscribe(session_token: @ann[:token], subscription: browser_subscription)
    expire_sessions("ann@shop.test")

    assert_empty Monk::Push.subscriptions("ann@shop.test")
    assert_equal 1, rows.size
    Monk::Auth.sweep!
    assert_empty rows, "ON DELETE CASCADE"
  end

  def test_a_subscription_past_the_browsers_expiration_time_stops_counting
    past = ((Time.now.to_f - 60) * 1000).to_i
    future = ((Time.now.to_f + 3600) * 1000).to_i
    Monk::Push.subscribe(session_token: @ann[:token], subscription: browser_subscription(expiration_time: past))
    Monk::Push.subscribe(session_token: @ann[:token], subscription: browser_subscription(expiration_time: future))

    assert_equal 1, Monk::Push.subscriptions("ann@shop.test").size
  end

  def test_subscribed_answers_for_many_subjects_in_one_go
    Monk::Push.subscribe(session_token: @ann[:token], subscription: browser_subscription)
    sign_in("bob@shop.test")

    answer = Monk::Push.subscribed(["ann@shop.test", "bob@shop.test", "cy@shop.test", "ann@shop.test"])

    assert_equal({ "ann@shop.test" => true, "bob@shop.test" => false, "cy@shop.test" => false }, answer)
    assert_equal({}, Monk::Push.subscribed([]))
  end

  def test_unsubscribe_forgets_that_browser
    subscription = browser_subscription
    Monk::Push.subscribe(session_token: @ann[:token], subscription: subscription)

    assert Monk::Push.unsubscribe(subscription["endpoint"])
    refute Monk::Push.unsubscribe(subscription["endpoint"])
    assert_empty rows
  end

  def test_sweep_deletes_what_no_longer_counts
    Monk::Push.subscribe(session_token: @ann[:token], subscription: browser_subscription)
    past = ((Time.now.to_f - 60) * 1000).to_i
    Monk::Push.subscribe(session_token: @ann[:token], subscription: browser_subscription(expiration_time: past))
    bob = sign_in("bob@shop.test")
    Monk::Push.subscribe(session_token: bob[:token], subscription: browser_subscription)
    cy = sign_in("cy@shop.test")
    Monk::Push.subscribe(session_token: cy[:token], subscription: browser_subscription)
    Monk::Auth.revoke(bob[:token])
    expire_sessions("cy@shop.test")

    assert_equal 3, Monk::Push.sweep!(batch_size: 1)
    assert_equal(["ann@shop.test"], rows.map { |row| row["subject"] })
    assert_raises(ArgumentError) { Monk::Push.sweep!(batch_size: 0) }
  end

  def test_a_subscription_a_browser_wouldnt_send_is_refused
    good = browser_subscription
    [
      "nope",
      good.except("endpoint"),
      good.merge("endpoint" => "http://push.example/send/1"),
      good.merge("endpoint" => "https://push.example/#{"x" * 2100}"),
      good.merge("keys" => { "p256dh" => good["keys"]["p256dh"] }),
      good.merge("keys" => { "p256dh" => "AAAA", "auth" => good["keys"]["auth"] }),
      good.merge("expirationTime" => "soon"),
    ].each do |subscription|
      assert_raises(Monk::Push::InvalidSubscriptionError, subscription.inspect[0, 80]) do
        Monk::Push.subscribe(session_token: @ann[:token], subscription: subscription)
      end
    end
    assert_empty rows
  end

  def test_symbol_keys_and_a_long_user_agent_are_fine
    subscription = browser_subscription
    symbols = { endpoint: subscription["endpoint"], keys: subscription["keys"].transform_keys(&:to_sym) }

    Monk::Push.subscribe(session_token: @ann[:token], subscription: symbols, user_agent: "x" * 2000)

    assert_equal 512, rows.first["user_agent"].length
  end

  private

  def rows
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec("SELECT * FROM push_subscriptions ORDER BY id").to_a }
  end

  def expire_sessions(subject)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("UPDATE sessions SET expires_at = now() - interval '1 minute' WHERE subject = $1", [subject])
    end
  end
end
