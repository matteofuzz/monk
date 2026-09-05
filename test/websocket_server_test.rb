require_relative "test_helper"
require "monk/websocket"
require "socket"

class WebSocketServerTest < Minitest::Test
  CLIENT_KEY = "dGhlIHNhbXBsZSBub25jZQ=="

  # Defined at class-body scope, not inline in a test method: self here is
  # WebSocketServerTest (a Class, always Ractor.shareable?), which is what
  # Server#run's block requires -- the identical constraint
  # StateRactor#update already documents (docs/ractor.md).
  ECHO_ONE_MESSAGE = proc do |connection|
    message = connection.read
    connection.write(message) if message
  end

  # The client tells this handler whether to be the slow one -- no shared
  # mutable state is closed over, since that would break the block's own
  # Ractor-shareability (the same constraint the guard test above proves).
  SLEEP_IF_TOLD_THEN_ECHO = proc do |connection|
    role = connection.read
    sleep 0.3 if role == "slow"
    connection.write("done")
  end

  RAISE_IF_TOLD_ELSE_ECHO = proc do |connection|
    role = connection.read
    raise "simulated handler crash" if role == "crash"

    connection.write("ok")
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

  # Frame.decode doesn't require the masked bit at all -- it just unmasks
  # conditionally -- so the test client can reuse Connection#read directly
  # as its own frame parser instead of duplicating frame-parsing logic.
  def read_frame(socket)
    Monk::WebSocket::Connection.new(socket).read
  end

  def test_run_raises_a_precise_error_for_an_unshareable_block
    server = Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1")
    local_state = +"captured"

    error = assert_raises(Monk::UnshareableBlockError) do
      server.run { |_connection| local_state }
    end
    assert_match(/not Ractor-shareable/, error.message)
  end

  def test_a_valid_handshake_gets_a_101_response
    server = start_server(&ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake!(socket)

    assert_match(%r{\AHTTP/1.1 101 Switching Protocols}, response)
    assert_match(/Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK\+xOo=/, response)
  ensure
    socket&.close
  end

  def test_read_and_write_round_trip_through_a_real_connection
    server = start_server(&ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)
    socket.write(Monk::WebSocket::Frame.encode("hello server", opcode: 0x1))

    assert_equal "hello server", read_frame(socket)
  ensure
    socket&.close
  end

  def test_accept_loop_does_not_block_on_a_slow_connection
    server = start_server(&SLEEP_IF_TOLD_THEN_ECHO)

    slow = TCPSocket.new("127.0.0.1", server.port)
    handshake!(slow)
    slow.write(Monk::WebSocket::Frame.encode("slow", opcode: 0x1))

    fast = TCPSocket.new("127.0.0.1", server.port)
    handshake!(fast)
    fast.write(Monk::WebSocket::Frame.encode("fast", opcode: 0x1))

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal "done", read_frame(fast)
    fast_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

    assert_operator fast_elapsed, :<, 0.2, "the fast connection waited on the slow one's Ractor"
    assert_equal "done", read_frame(slow)
  ensure
    slow&.close
    fast&.close
  end

  def test_malformed_handshake_gets_a_400_and_the_socket_is_closed
    server = start_server(&ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    socket.write("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n") # no Upgrade/Connection/Sec-WebSocket-Key at all

    response = +""
    until response.end_with?("\r\n\r\n")
      byte = socket.read(1)
      break if byte.nil?

      response << byte
    end

    assert_match(%r{\AHTTP/1.1 400 Bad Request}, response)
    assert_nil socket.read(1), "expected the server to close the socket after a malformed handshake"
  ensure
    socket&.close
  end

  def test_a_handler_exception_is_isolated_to_its_own_connection
    server = start_server(&RAISE_IF_TOLD_ELSE_ECHO)

    crashing = TCPSocket.new("127.0.0.1", server.port)
    handshake!(crashing)
    crashing.write(Monk::WebSocket::Frame.encode("crash", opcode: 0x1))
    assert_nil crashing.read(1), "expected the crashing connection's socket to be closed, not left hanging"

    healthy = TCPSocket.new("127.0.0.1", server.port)
    handshake!(healthy)
    healthy.write(Monk::WebSocket::Frame.encode("fine", opcode: 0x1))

    assert_equal "ok", read_frame(healthy)
  ensure
    crashing&.close
    healthy&.close
  end
end
