require_relative "test_helper"
require "monk/websocket"
require "socket"

# The committed, automated version of docs/websocket.md's "End-to-end
# spike" (PLAN-WEBSOCKET.md Seam U) -- the only place non-blocking accept
# and per-connection failure isolation are proven under real concurrency,
# in the same spirit as test/ractor_integration_test.rb's hammer test for
# StateRactor.
class WebSocketRactorIntegrationTest < Minitest::Test
  CLIENT_KEY = "dGhlIHNhbXBsZSBub25jZQ=="

  # Mirrors the spike exactly: one ordinary connection, one that sleeps
  # before replying, one whose payload is engineered to raise inside the
  # handler. Defined at class-body scope -- see websocket_server_test.rb's
  # comment on ECHO_ONE_MESSAGE for why.
  DISPATCH_BY_ROLE = proc do |connection|
    role = connection.read
    case role
    when "slow"
      sleep 0.5
      connection.write("done")
    when "crash"
      raise "simulated bad frame"
    else
      connection.write("done")
    end
  end

  def self.subscribe_then_wait_for_disconnect(registry)
    Ractor.make_shareable(
      proc do |connection|
        connection.subscribe(registry, :room1)
        loop { break unless connection.read }
      end,
    )
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

  def read_frame(socket)
    Monk::WebSocket::Connection.new(socket).read
  end

  def wait_until(timeout: 1.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  def test_ordinary_and_crashing_connections_complete_without_waiting_on_a_slow_one
    server = start_server(&DISPATCH_BY_ROLE)

    slow = TCPSocket.new("127.0.0.1", server.port)
    handshake!(slow)
    slow.write(Monk::WebSocket::Frame.encode("slow", opcode: 0x1))

    ordinary = TCPSocket.new("127.0.0.1", server.port)
    handshake!(ordinary)
    ordinary.write(Monk::WebSocket::Frame.encode("ordinary", opcode: 0x1))

    crashing = TCPSocket.new("127.0.0.1", server.port)
    handshake!(crashing)
    crashing.write(Monk::WebSocket::Frame.encode("crash", opcode: 0x1))

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal "done", read_frame(ordinary)
    ordinary_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    assert_operator ordinary_elapsed, :<, 0.3, "the ordinary connection waited on the slow one's Ractor"

    assert_nil crashing.read(1), "expected the crashing connection's socket to be closed, not left hanging"
    crash_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    assert_operator crash_elapsed, :<, 0.3, "the crashing connection waited on the slow one's Ractor"

    # A brand-new connection accepted while "slow" is still mid-sleep --
    # proves the accept loop itself kept running, not just that three
    # near-simultaneous connections happened to queue in the OS backlog
    # before #run's loop ever got a chance to block.
    late = TCPSocket.new("127.0.0.1", server.port)
    assert_match(%r{\AHTTP/1.1 101}, handshake!(late))

    # The slow connection itself still completes correctly -- it isn't
    # merely tolerated, its result isn't lost either.
    assert_equal "done", read_frame(slow)
  ensure
    slow&.close
    ordinary&.close
    crashing&.close
    late&.close
  end

  def test_broadcast_from_an_independent_ractor_reaches_every_connection_on_the_key
    registry = Monk::WebSocket::Registry.new
    server = start_server(&self.class.subscribe_then_wait_for_disconnect(registry))

    sockets = Array.new(3) do
      socket = TCPSocket.new("127.0.0.1", server.port)
      handshake!(socket)
      socket.write(Monk::WebSocket::Frame.encode("subscribe", opcode: 0x1))
      socket
    end

    wait_until { registry.count(:room1) == 3 }

    # Neither the main Ractor nor any connection's own -- a fourth,
    # independent Ractor performs the broadcast (PLAN-WEBSOCKET.md step
    # 28's literal wording), proving Registry's own synchronous "ask"
    # shape is safe from any caller, not just the ones already exercised.
    broadcaster = Ractor.new(registry) { |r| r.broadcast(:room1, "hello everyone") }
    broadcaster.value

    sockets.each { |socket| assert_equal "hello everyone", read_frame(socket) }
  ensure
    sockets&.each(&:close)
  end
end
