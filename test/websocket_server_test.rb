require_relative "test_helper"
require "open3"
require "rbconfig"
require "monk/websocket"
require "socket"

class WebSocketServerTest < Minitest::Test
  include WebSocketTestHelpers

  # Defined at class-body scope, not inline in a test method: self here is
  # WebSocketServerTest (a Class, always Ractor.shareable?), which is what
  # Server#run's block requires -- the identical constraint
  # StateRactor#update already documents (docs/design/ractor.md).
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

  # Item 4: the request is read through the socket's buffer, so a frame
  # sent in the same packet as the request still reaches the handler.
  def test_a_frame_sent_right_behind_the_request_is_not_lost
    server = start_server(&ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    socket.write(handshake_request + Monk::WebSocket::Frame.encode("right behind", opcode: 0x1))
    read_response_head(socket)

    assert_equal "right behind", read_frame(socket)
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

  # docs/plan-ws-connect-ceiling.md item 1: at max_handshakes:, the accept
  # loop waits for a handshake to end before it takes the next connect.
  def test_at_max_handshakes_a_new_connect_waits_for_a_handshake_to_end
    server = start_server(max_handshakes: 2, &ECHO_ONE_MESSAGE)

    # Connected, but never sending a request: both stay in their handshake.
    silent = Array.new(2) { TCPSocket.new("127.0.0.1", server.port) }
    sleep 0.1
    waiting = TCPSocket.new("127.0.0.1", server.port)
    waiting.write(handshake_request)

    assert_nil waiting.wait_readable(0.3), "a third handshake was served past the cap"

    silent.first.close
    response = read_response_head(waiting)

    assert_match(%r{\AHTTP/1.1 101 Switching Protocols}, response)
  ensure
    silent&.each(&:close)
    waiting&.close
  end

  def test_a_refused_handshake_frees_its_slot
    server = start_server(max_handshakes: 1, &ECHO_ONE_MESSAGE)

    3.times do
      socket = TCPSocket.new("127.0.0.1", server.port)
      socket.write("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

      assert_match(%r{\AHTTP/1.1 400 Bad Request}, read_response_head(socket))
      socket.close
    end

    socket = TCPSocket.new("127.0.0.1", server.port)

    assert_match(%r{\AHTTP/1.1 101}, handshake!(socket))
  ensure
    socket&.close
  end

  # Item 2: a socket that sends nothing can't hold a handshake slot forever.
  def test_a_client_that_sends_nothing_is_dropped_after_handshake_timeout
    server = start_server(handshake_timeout: 0.2, &ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)

    assert socket.wait_readable(2), "the silent socket was never dropped"
    assert_nil socket.read(1)
  ensure
    socket&.close
  end

  def test_a_timed_out_handshake_frees_its_slot
    server = start_server(max_handshakes: 1, handshake_timeout: 0.2, &ECHO_ONE_MESSAGE)

    silent = TCPSocket.new("127.0.0.1", server.port)
    sleep 0.05
    socket = TCPSocket.new("127.0.0.1", server.port)

    assert_match(%r{\AHTTP/1.1 101}, handshake!(socket))
  ensure
    silent&.close
    socket&.close
  end

  def test_the_handshake_timeout_ends_with_the_handshake
    server = start_server(handshake_timeout: 0.1, &ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)
    sleep 0.3
    socket.write(Monk::WebSocket::Frame.encode("still here", opcode: 0x1))

    assert_equal "still here", read_frame(socket)
  ensure
    socket&.close
  end

  def test_a_request_head_past_the_size_limit_is_refused_as_too_large
    server = start_server(&ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    socket.write("GET / HTTP/1.1\r\nCookie: #{"a" * Monk::WebSocket::Handshake::MAX_REQUEST_SIZE}")

    assert_match(%r{\AHTTP/1.1 431 Request Header Fields Too Large}, read_response_head(socket))
  ensure
    socket&.close
  end

  def test_handshake_timeout_must_be_positive
    [0, -1, nil].each do |value|
      error = assert_raises(ArgumentError) do
        Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1", handshake_timeout: value)
      end
      assert_match(/handshake_timeout must be positive/, error.message)
    end
  end

  def test_max_handshakes_must_be_a_positive_integer
    [0, -1, 1.5, nil].each do |value|
      error = assert_raises(ArgumentError) do
        Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1", max_handshakes: value)
      end
      assert_match(/max_handshakes must be a positive Integer/, error.message)
    end
  end

  # TERM is how docker stop, Kubernetes, Fly, Render and systemd stop a
  # process -- every deploy. The server handles it like Ctrl-C: it stops
  # accepting, run returns, and the script ends with exit 0, as bin/server
  # and bin/jobs do. Open connections are still dropped (no close frame;
  # docs/design/websocket.md, "Stopping the server").
  def test_term_makes_run_return_and_the_process_exit_zero
    script = <<~RUBY
      $LOAD_PATH.unshift #{File.expand_path("../lib", __dir__).inspect}
      require "monk/websocket"
      module TermProbe
        HANDLER = proc { |connection| loop { break unless connection.read } }
      end
      server = Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1")
      puts server.port
      $stdout.flush
      server.run(&TermProbe::HANDLER)
      puts "run returned"
    RUBY
    _stdin, out, _err, thread = Open3.popen3(RbConfig.ruby, "-W0", "-e", script)
    port = Integer(out.gets)
    client = TCPSocket.new("127.0.0.1", port)
    handshake!(client)

    Process.kill("TERM", thread.pid)
    status = thread.value

    assert_equal 0, status.exitstatus, "expected exit 0, got #{status.inspect}"
    assert_equal "run returned\n", out.read
  ensure
    client&.close
  end
end
