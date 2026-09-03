require_relative "test_helper"
require "monk/websocket"

class WebSocketRegistryTest < Minitest::Test
  # No real socket needed to prove the registry's own bookkeeping
  # (PLAN-WEBSOCKET.md step 16) -- a bare Ractor::Port stands in for
  # whatever a real connection would register.
  def test_broadcast_delivers_to_every_port_registered_under_the_key
    registry = Monk::WebSocket::Registry.new
    port_a = Ractor::Port.new
    port_b = Ractor::Port.new

    registry.register(:room1, port_a)
    registry.register(:room1, port_b)
    registry.broadcast(:room1, "hi")

    assert_equal "hi", port_a.receive
    assert_equal "hi", port_b.receive
  ensure
    port_a&.close
    port_b&.close
  end

  def test_broadcast_does_not_deliver_to_a_port_registered_under_a_different_key
    registry = Monk::WebSocket::Registry.new
    other_key_port = Ractor::Port.new
    registry.register(:other_room, other_key_port)

    registry.broadcast(:room1, "hi")

    refute_delivered(other_key_port)
  ensure
    other_key_port&.close
  end

  def test_unregister_removes_the_port_from_future_broadcasts
    registry = Monk::WebSocket::Registry.new
    port = Ractor::Port.new
    registry.register(:room1, port)
    registry.unregister(:room1, port)

    registry.broadcast(:room1, "hi")

    refute_delivered(port)
  ensure
    port&.close
  end

  def test_count_reflects_registrations_and_unregistrations
    registry = Monk::WebSocket::Registry.new
    port = Ractor::Port.new

    assert_equal 0, registry.count(:room1)
    registry.register(:room1, port)
    assert_equal 1, registry.count(:room1)
    registry.unregister(:room1, port)
    assert_equal 0, registry.count(:room1)
  ensure
    port&.close
  end

  private

  # Ractor::Port has no non-blocking/"try" receive, so this is the same
  # bounded-wait shape persistence_test.rb already uses elsewhere in this
  # suite to assert a negative.
  def refute_delivered(port, timeout: 0.1)
    received = nil
    waiter = Thread.new { received = port.receive }
    delivered = waiter.join(timeout)
    waiter.kill unless delivered

    refute delivered, "expected nothing to be delivered, but got #{received.inspect}"
  end
end
