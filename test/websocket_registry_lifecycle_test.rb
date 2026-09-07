require_relative "test_helper"
require "monk/websocket"
require "socket"

class WebSocketRegistryLifecycleTest < Minitest::Test
  include WebSocketTestHelpers

  KEY = :room1

  # Defined at class-body scope -- see websocket_server_test.rb's comment
  # on ECHO_ONE_MESSAGE for why. The registry itself is passed in as the
  # first message read from the socket-shaped handshake data isn't
  # available here, so tests inject it via a wrapping proc built per-test
  # (still class-body scope, since REGISTRY_HANDLER is itself built inside
  # a class method, keeping self a Class throughout).
  def self.subscribe_then_wait_for_disconnect(registry)
    Ractor.make_shareable(
      proc do |connection|
        connection.subscribe(registry, KEY)
        loop { break unless connection.read }
      end,
    )
  end

  def self.subscribe_then_crash(registry)
    Ractor.make_shareable(
      proc do |connection|
        connection.subscribe(registry, KEY)
        raise "simulated handler crash"
      end,
    )
  end

  # The client tells this handler which key to subscribe under, so one
  # handler can serve both "room1" connections and the "other room" one in
  # the broadcast test below -- no per-test closure state, same
  # shareability constraint as everywhere else in this file.
  def self.subscribe_by_first_message_then_wait_for_disconnect(registry)
    Ractor.make_shareable(
      proc do |connection|
        key = connection.read
        connection.subscribe(registry, key.to_sym) if key
        loop { break unless connection.read }
      end,
    )
  end

  # No non-blocking read on a raw socket either, so this is the same
  # bounded-wait shape websocket_registry_test.rb uses to assert a
  # negative against a Ractor::Port.
  def refute_delivered(socket, timeout: 0.1)
    received = nil
    waiter = Thread.new { received = read_frame(socket) }
    delivered = waiter.join(timeout)
    waiter.kill unless delivered

    refute delivered, "expected no broadcast delivered, but got #{received.inspect}"
  end

  def test_a_connection_registers_itself_and_unregisters_on_disconnect
    registry = Monk::WebSocket::Registry.new
    server = start_server(&self.class.subscribe_then_wait_for_disconnect(registry))

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)

    wait_until { registry.count(KEY) == 1 }
    assert_equal 1, registry.count(KEY)

    socket.close

    wait_until { registry.count(KEY).zero? }
    assert_equal 0, registry.count(KEY)
  ensure
    socket&.close
  end

  def test_a_crashed_handler_does_not_leak_a_stale_registry_entry
    registry = Monk::WebSocket::Registry.new
    server = start_server(&self.class.subscribe_then_crash(registry))

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)

    wait_until { registry.count(KEY).zero? }
    assert_equal 0, registry.count(KEY)
  ensure
    socket&.close
  end

  def test_broadcast_reaches_both_connections_on_a_key_and_neither_of_a_different_key
    registry = Monk::WebSocket::Registry.new
    server = start_server(&self.class.subscribe_by_first_message_then_wait_for_disconnect(registry))

    room1_a = TCPSocket.new("127.0.0.1", server.port)
    handshake!(room1_a)
    room1_a.write(Monk::WebSocket::Frame.encode("room1", opcode: 0x1))

    room1_b = TCPSocket.new("127.0.0.1", server.port)
    handshake!(room1_b)
    room1_b.write(Monk::WebSocket::Frame.encode("room1", opcode: 0x1))

    room2 = TCPSocket.new("127.0.0.1", server.port)
    handshake!(room2)
    room2.write(Monk::WebSocket::Frame.encode("room2", opcode: 0x1))

    wait_until { registry.count(:room1) == 2 && registry.count(:room2) == 1 }

    registry.broadcast(:room1, "hello room1")

    assert_equal "hello room1", read_frame(room1_a)
    assert_equal "hello room1", read_frame(room1_b)
    refute_delivered(room2)
  ensure
    room1_a&.close
    room1_b&.close
    room2&.close
  end
end
