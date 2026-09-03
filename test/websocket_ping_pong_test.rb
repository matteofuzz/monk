require_relative "test_helper"
require "monk/websocket"
require "socket"

class WebSocketPingPongTest < Minitest::Test
  CLIENT_KEY = "dGhlIHNhbXBsZSBub25jZQ=="

  # Defined at class-body scope -- see websocket_server_test.rb's comment
  # on ECHO_ONE_MESSAGE for why.
  ECHO_LOOP = proc do |connection|
    loop do
      message = connection.read
      break unless message

      connection.write(message)
    end
  end

  def teardown
    @server_thread&.kill
    @server_thread&.join
  end

  def start_server(&block)
    server = Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1")
    @server_thread = Thread.new { server.run(&block) }
    server
  end

  def handshake!(socket)
    socket.write(
      "GET / HTTP/1.1\r\n" \
      "Host: 127.0.0.1\r\n" \
      "Upgrade: websocket\r\n" \
      "Connection: Upgrade\r\n" \
      "Sec-WebSocket-Key: #{CLIENT_KEY}\r\n" \
      "Sec-WebSocket-Version: 13\r\n" \
      "\r\n",
    )
    response = +""
    until response.end_with?("\r\n\r\n")
      byte = socket.read(1)
      return nil if byte.nil?

      response << byte
    end
    response
  end

  # Deliberately independent of Connection#read (which, once ping/pong
  # auto-answering lands, hides them from app code) -- reads whatever
  # frame the server actually sent, opcode included.
  def read_raw_frame(socket)
    header = socket.read(2)
    return nil unless header

    byte1 = header.getbyte(1)
    length_indicator = byte1 & 0x7F
    extended =
      case length_indicator
      when 126 then socket.read(2)
      when 127 then socket.read(8)
      else ""
      end
    length = case length_indicator
             when 126 then extended.unpack1("n")
             when 127 then extended.unpack1("Q>")
             else length_indicator
             end
    payload = length.zero? ? "" : socket.read(length)

    Monk::WebSocket::Frame.decode(header + extended.to_s + payload.to_s)
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
