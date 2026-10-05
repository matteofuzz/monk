require_relative "test_helper"
require "timeout"
require "monk/websocket"
require "monk/websocket/redis_fanout"

# RedisFanout wraps a Registry for cross-process fan-out (docs/history/plan-websocket.md
# Phase 6). Two concerns: it has to be usable the exact way Registry
# already is -- held behind a module constant, read from every connection's
# own Ractor -- and its Redis round trip has to actually deliver across two
# instances while dropping each instance's own echo. It subscribes only
# once #listen! is called -- by the one process that holds sockets -- so a
# publish-only process holds no subscriber connection at all.
class WebSocketRedisFanoutTest < Minitest::Test
  include RedisTestHelpers
  include WebSocketTestHelpers # for #wait_until only -- no server/socket use here

  def test_a_fanout_instance_is_frozen_and_ractor_shareable
    skip_unless_redis_available

    fanout = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_test_url)

    assert fanout.frozen?
    assert Ractor.shareable?(fanout), "expected RedisFanout to be Ractor-shareable, same as Registry"
  end

  # The real-world shape this exists for: an app holds RegisterFanout
  # behind a module constant (bin/websocket_server's ChatServer::REGISTRY),
  # read from inside a connection's own dedicated Ractor -- which raises
  # Ractor::IsolationError unless the constant's value is shareable.
  def test_a_fanout_instance_is_readable_as_a_module_constant_from_a_worker_ractor
    skip_unless_redis_available

    fanout = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_test_url)
    holder = Module.new
    holder.const_set(:REGISTRY, fanout)

    result = Ractor.new(holder) { |h| h::REGISTRY.count(:room1) }.value

    assert_equal 0, result
  end

  # A publish-only process (bin/server, bin/jobs) builds the same fanout
  # from the same config/live.rb, and never needs to hear other processes'
  # broadcasts -- so constructing one mustn't subscribe.
  def test_constructing_opens_no_subscriber_connection
    skip_unless_redis_available

    before = subscriber_count
    Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_test_url)

    assert_equal before, subscriber_count
  end

  # #listen! returns once the psubscribe is in effect, so a broadcast sent
  # right after it can't be missed -- and calling it again changes nothing.
  def test_listen_bang_opens_one_subscriber_connection_and_is_idempotent
    skip_unless_redis_available

    fanout = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_test_url)
    before = subscriber_count

    assert_same fanout, fanout.listen!
    assert_equal before + 1, subscriber_count

    fanout.listen!
    assert_equal before + 1, subscriber_count
  end

  def test_register_before_listen_bang_raises
    skip_unless_redis_available

    fanout = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_test_url)
    port = Ractor::Port.new

    error = assert_raises(Monk::WebSocket::NotListeningError) { fanout.register(:room1, port) }
    assert_match(/listen!/, error.message)
  ensure
    port&.close
  end

  def test_listen_bang_raises_when_redis_is_unreachable
    fanout = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: "redis://127.0.0.1:1/0")

    error = assert_raises(Monk::WebSocket::ListenError) { fanout.listen! }
    assert_match(/RedisFanout/, error.message)
  end

  def test_broadcast_from_one_instance_reaches_a_connection_registered_on_a_sibling_instance
    skip_unless_redis_available

    fanout_a = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_test_url)
    fanout_b = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_test_url).listen!

    port = Ractor::Port.new
    fanout_b.register(:room1, port)
    received = []
    reader = Thread.new { loop { received << port.receive } }

    fanout_a.broadcast(:room1, "hello from A")

    wait_until { received.any? }
    assert_equal ["hello from A"], received
  ensure
    reader&.kill
    port&.close
  end

  def test_disconnect_publisher_closes_this_ractors_publisher
    skip_unless_redis_available

    Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_test_url).broadcast(:room1, "x")
    client = Ractor.current[:monk_redis_fanout_publisher]
    assert client.connected?, "control: broadcasting connected it"

    Monk::WebSocket::RedisFanout.disconnect_publisher

    refute client.connected?
    assert_nil Ractor.current[:monk_redis_fanout_publisher]
    Monk::WebSocket::RedisFanout.disconnect_publisher # none left: a no-op
  end

  # Without the origin tag, A's own subscriber would relay A's own
  # broadcast back into registry_a a second time -- a connection
  # registered directly on registry_a would see it twice.
  def test_a_fanouts_own_broadcast_is_not_delivered_twice_to_its_own_registry
    skip_unless_redis_available

    fanout_a = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_test_url).listen!
    # A second listening instance on the same Redis, standing in for a
    # sibling process -- A's own subscriber is the one that must drop A's
    # publish when it comes back.
    Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_test_url).listen!

    port = Ractor::Port.new
    fanout_a.register(:room1, port)
    received = []
    reader = Thread.new { loop { received << port.receive } }

    fanout_a.broadcast(:room1, "only once")

    wait_until { received.any? }
    # Give a wrongly-undropped echo time to complete its Redis round trip
    # and arrive -- if the origin-tag guard were removed, it would show up
    # here as a second entry.
    sleep 0.3
    assert_equal ["only once"], received
  ensure
    reader&.kill
    port&.close
  end

  # Redis dropping the subscriber's connection (a restart, a failover)
  # used to end its Ractor silently. It resubscribes, then asks every open
  # socket to close: whatever was published meanwhile is lost, so each
  # page has to resync. A broadcast after that arrives as usual.
  def test_the_listener_resubscribes_after_its_connection_is_dropped_and_asks_sockets_to_close
    skip_unless_redis_available

    fanout_a = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_test_url)
    fanout_b = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_test_url).listen!
    port = Ractor::Port.new
    fanout_b.register(:room1, port)

    drop_subscriber_connections

    message = Timeout.timeout(5) { port.receive }
    assert_equal Monk::WebSocket::CloseRequest.new(code: 1011, reason: "missed broadcasts"), message
    fanout_a.broadcast(:room1, "after the drop")
    assert_equal "after the drop", Timeout.timeout(2) { port.receive }
  ensure
    port&.close
  end

  def test_a_malformed_message_is_skipped_and_the_next_one_still_arrives
    skip_unless_redis_available

    fanout_a = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_test_url)
    fanout_b = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_test_url).listen!
    port = Ractor::Port.new
    fanout_b.register(:room1, port)

    redis = Redis.new(url: redis_test_url)
    redis.publish("#{Monk::WebSocket::RedisFanout::CHANNEL_PREFIX}room1", "no origin separator")
    fanout_a.broadcast(:room1, "after the bad one")

    assert_equal "after the bad one", Timeout.timeout(2) { port.receive }
  ensure
    redis&.close
    port&.close
  end

  private

  # Clients with at least one pattern subscription (test/support/live_ws_process.rb).
  def subscriber_count
    redis = Redis.new(url: redis_test_url)
    redis.call("CLIENT", "LIST").scan(/psub=(\d+)/).count { |(count)| count.to_i.positive? }
  ensure
    redis&.close
  end

  # Every connection in pattern-subscribe mode, as a Redis restart would.
  def drop_subscriber_connections
    redis = Redis.new(url: redis_test_url)
    redis.call("CLIENT", "KILL", "TYPE", "pubsub")
  ensure
    redis&.close
  end
end
