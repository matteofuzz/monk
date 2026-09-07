require_relative "test_helper"
require "monk/websocket"
require "socket"

class WebSocketPingPongTest < Minitest::Test
  include WebSocketTestHelpers

  # Defined at class-body scope -- see websocket_server_test.rb's comment
  # on ECHO_ONE_MESSAGE for why.
  ECHO_LOOP = proc do |connection|
    loop do
      message = connection.read
      break unless message

      connection.write(message)
    end
  end

  def test_a_ping_gets_an_immediate_pong_without_reaching_the_handler
    server = start_server(&ECHO_LOOP)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)
    socket.write(Monk::WebSocket::Frame.encode("ping payload", opcode: 0x9))

    frame = read_raw_frame(socket)
    assert_equal 0xA, frame[:opcode]
    assert_equal "ping payload", frame[:payload]
  ensure
    socket&.close
  end

  def test_the_read_loop_continues_normally_after_a_ping
    server = start_server(&ECHO_LOOP)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)
    socket.write(Monk::WebSocket::Frame.encode("", opcode: 0x9))
    read_raw_frame(socket) # the pong -- discard, already asserted above

    socket.write(Monk::WebSocket::Frame.encode("hello", opcode: 0x1))
    assert_equal "hello", read_raw_frame(socket)[:payload]
  ensure
    socket&.close
  end

  def test_an_unsolicited_pong_is_ignored_and_does_not_reach_the_handler
    server = start_server(&ECHO_LOOP)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)
    socket.write(Monk::WebSocket::Frame.encode("unsolicited", opcode: 0xA))
    socket.write(Monk::WebSocket::Frame.encode("hello", opcode: 0x1))

    assert_equal "hello", read_raw_frame(socket)[:payload]
  ensure
    socket&.close
  end
end
