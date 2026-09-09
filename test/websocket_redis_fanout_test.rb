require_relative "test_helper"
require "monk/websocket"
require "monk/websocket/redis_fanout"

# RedisFanout wraps a Registry for cross-process fan-out (PLAN-WEBSOCKET.md
# Phase 6). Two concerns: it has to be usable the exact way Registry
# already is -- held behind a module constant, read from every connection's
# own Ractor -- and its Redis round trip has to actually deliver across two
# instances while dropping each instance's own echo.
class WebSocketRedisFanoutTest < Minitest::Test
  include RedisTestHelpers
  include WebSocketTestHelpers # for #wait_until only -- no server/socket use here

  # Construction always spawns a real subscriber Ractor that connects
  # immediately (there's no lazy/offline path), so this needs a live Redis
  # the same as every other test here -- otherwise the background Ractor's
  # own connection failure prints an unrelated, misleading stack trace.
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

  def test_broadcast_from_one_instance_reaches_a_connection_registered_on_a_sibling_instance
    skip_unless_redis_available

    registry_a = Monk::WebSocket::Registry.new
    registry_b = Monk::WebSocket::Registry.new
    fanout_a = Monk::WebSocket::RedisFanout.new(registry_a, redis_url: redis_test_url)
    Monk::WebSocket::RedisFanout.new(registry_b, redis_url: redis_test_url)
    wait_for_subscribers

    port = Ractor::Port.new
    registry_b.register(:room1, port)
    received = []
    reader = Thread.new { loop { received << port.receive } }

    fanout_a.broadcast(:room1, "hello from A")

    wait_until { received.any? }
    assert_equal ["hello from A"], received
  ensure
    reader&.kill
    port&.close
  end

  # Without the origin tag, A's own subscriber would relay A's own
  # broadcast back into registry_a a second time -- a connection
  # registered directly on registry_a would see it twice.
  def test_a_fanouts_own_broadcast_is_not_delivered_twice_to_its_own_registry
    skip_unless_redis_available

    registry_a = Monk::WebSocket::Registry.new
    fanout_a = Monk::WebSocket::RedisFanout.new(registry_a, redis_url: redis_test_url)
    # A second instance on the same Redis, standing in for a sibling
    # process, so there's a live subscriber for A's publish to echo past --
    # without it, this test would pass even with the echo-guard removed.
    Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_test_url)
    wait_for_subscribers

    port = Ractor::Port.new
    registry_a.register(:room1, port)
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

  private

  # RedisFanout#initialize spawns its subscriber Ractor and returns
  # immediately -- it doesn't wait for that Ractor's own psubscribe to
  # actually take effect on the Redis server. Publish is fire-and-forget
  # (no queue/replay for a subscriber that isn't listening yet), so a
  # broadcast sent before this window closes can simply be lost. A fixed
  # wait here, not a retry loop, keeps each test's later single #broadcast
  # call meaning exactly one message went out.
  def wait_for_subscribers
    sleep 0.3
  end
end
