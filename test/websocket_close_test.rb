require_relative "test_helper"
require "monk/websocket"
require "socket"

class WebSocketCloseTest < Minitest::Test
  CLIENT_KEY = "dGhlIHNhbXBsZSBub25jZQ=="

  # Defined at class-body scope -- see websocket_server_test.rb's comment
  # on ECHO_ONE_MESSAGE for why this isn't inline in a test method.
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

  # Deliberately independent of Connection#read (which, once Phase 3
  # lands, hides close frames from app code) -- this is the test's own
  # "raw client" frame reader, reading whatever frame type the server
  # actually sent, opcode included.
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
