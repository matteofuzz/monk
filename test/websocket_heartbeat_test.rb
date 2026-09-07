require_relative "test_helper"
require "monk/websocket"
require "socket"

class WebSocketHeartbeatTest < Minitest::Test
  include WebSocketTestHelpers

  # Defined at class-body scope -- see websocket_server_test.rb's comment
  # on ECHO_ONE_MESSAGE for why. Never reads, so nothing but the
  # heartbeat itself ever writes to the socket.
  WAIT_FOR_DISCONNECT = proc do |connection|
    loop { break unless connection.read }
  end

  def test_ping_interval_sends_an_unsolicited_ping_without_any_client_message
    server = start_server(ping_interval: 0.05, &WAIT_FOR_DISCONNECT)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)

    frame = read_raw_frame(socket)

    assert_equal 0x9, frame[:opcode]
  ensure
    socket&.close
  end

  def test_ping_interval_keeps_sending_pings_on_the_configured_cadence
    server = start_server(ping_interval: 0.05, &WAIT_FOR_DISCONNECT)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)

    3.times { assert_equal 0x9, read_raw_frame(socket)[:opcode] }
  ensure
    socket&.close
  end

  def test_without_ping_interval_no_ping_is_ever_sent
    server = start_server(&WAIT_FOR_DISCONNECT)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)

    refute_delivered(socket, timeout: 0.2)
  ensure
    socket&.close
  end

  def test_ping_interval_must_be_positive
    error = assert_raises(ArgumentError) { Monk::WebSocket::Server.new(port: 0, ping_interval: 0) }
    assert_match(/ping_interval/, error.message)

    error = assert_raises(ArgumentError) { Monk::WebSocket::Server.new(port: 0, ping_interval: -1) }
    assert_match(/ping_interval/, error.message)
  end

  def test_the_heartbeat_thread_does_not_outlive_the_socket
    server = start_server(ping_interval: 0.02, &WAIT_FOR_DISCONNECT)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)
    read_raw_frame(socket) # at least one ping, to prove the thread actually started
    socket.close

    # A background heartbeat thread still writing to an already-closed
    # socket would surface as a Thread.report_on_exception warning on
    # $stderr, or (worse) a raised IOError -- give it a few cadences to
    # prove it quietly stops instead.
    sleep 0.1
  end

  private

  # No non-blocking read on a raw socket, so this is the same bounded-wait
  # shape websocket_registry_test.rb uses to assert a negative.
  def refute_delivered(socket, timeout:)
    received = nil
    waiter = Thread.new { received = read_raw_frame(socket) }
    delivered = waiter.join(timeout)
    waiter.kill unless delivered

    refute delivered, "expected no frame, but got #{received.inspect}"
  end
end
