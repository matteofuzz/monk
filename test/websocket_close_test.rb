require_relative "test_helper"
require "monk/websocket"
require "socket"

class WebSocketCloseTest < Minitest::Test
  include WebSocketTestHelpers

  # Defined at class-body scope -- see websocket_server_test.rb's comment
  # on ECHO_ONE_MESSAGE for why this isn't inline in a test method.
  ECHO_LOOP = proc do |connection|
    loop do
      message = connection.read
      break unless message

      connection.write(message)
    end
  end

  def test_receiving_a_close_frame_gets_a_close_frame_back_and_the_socket_closes
    server = start_server(&ECHO_LOOP)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)
    socket.write(Monk::WebSocket::Frame.encode("", opcode: 0x8))

    frame = read_raw_frame(socket)
    assert_equal 0x8, frame[:opcode]
    assert_nil socket.read(1), "expected the server to close the socket after the close handshake"
  ensure
    socket&.close
  end

  SERVER_INITIATED_CLOSE = proc { |connection| connection.close(code: 4000, reason: "bye") }

  def test_connection_close_sends_a_close_frame_and_closes_the_socket
    server = start_server(&SERVER_INITIATED_CLOSE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)

    frame = read_raw_frame(socket)
    assert_equal 0x8, frame[:opcode]
    assert_equal [4000].pack("n") + "bye", frame[:payload]
    assert_nil socket.read(1), "expected the socket to be closed after Connection#close"
  ensure
    socket&.close
  end

  def test_an_abrupt_disconnect_is_observed_as_read_returning_nil_and_the_ractor_exits_cleanly
    server = start_server(&ECHO_LOOP)

    abrupt = TCPSocket.new("127.0.0.1", server.port)
    handshake!(abrupt)
    abrupt.close # TCP EOF, no close frame -- ECHO_LOOP's #read must return nil, not hang or raise

    # A second, independent connection still working proves the abrupt
    # disconnect's Ractor exited cleanly rather than hanging or crashing
    # the accept loop.
    healthy = TCPSocket.new("127.0.0.1", server.port)
    handshake!(healthy)
    healthy.write(Monk::WebSocket::Frame.encode("still alive", opcode: 0x1))

    assert_equal "still alive", read_raw_frame(healthy)[:payload]
  ensure
    healthy&.close
  end
end
