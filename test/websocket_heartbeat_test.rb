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

  # Subscribes, so the registry shows when the connection's cleanup has
  # run, then writes until the socket fails: with a client that never
  # reads, the kernel's buffers fill and a write blocks holding the
  # connection's write mutex, as a relay's does on a dead peer.
  FLOOD_REGISTRY = Monk::WebSocket::Registry.new
  FLOOD = proc do |connection|
    connection.subscribe(FLOOD_REGISTRY, :flood)
    chunk = "x" * 65_536
    loop { connection.write(chunk) }
  end

  def setup
    lower_min_ping_interval!
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

    # Answered, as any client does: an unanswered ping gets the socket
    # closed after IDLE_PINGS intervals.
    3.times do
      assert_equal 0x9, read_raw_frame(socket)[:opcode]
      socket.write(Monk::WebSocket::Frame.encode("", opcode: 0xA))
    end
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

  def test_ping_interval_under_the_minimum_is_refused
    replace_min_ping_interval(@original_min_ping_interval)

    error = assert_raises(ArgumentError) { Monk::WebSocket::Server.new(port: 0, ping_interval: 4.9) }
    assert_match(/ping_interval must be at least 5/, error.message)
    Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1", ping_interval: 5)
  end

  # A peer that vanished (a phone that changed network) sends nothing, not
  # even a pong: closed after IDLE_PINGS intervals, not left open forever.
  def test_a_silent_client_is_closed_after_two_ping_intervals
    server = start_server(ping_interval: 0.05, &WAIT_FOR_DISCONNECT)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    frames = []
    while (frame = read_frame_or_eof(socket))
      frames << frame[:opcode]
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_includes frames, 0x9, "expected pings before the close"
    assert_operator elapsed, :>=, 0.09
    assert_operator elapsed, :<, 1.0
  ensure
    socket&.close
  end

  def test_a_client_that_answers_pings_stays_open
    server = start_server(ping_interval: 0.05, &WAIT_FOR_DISCONNECT)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)

    # Ten intervals, each ping answered with a pong.
    10.times do
      frame = read_raw_frame(socket)
      assert_equal 0x9, frame[:opcode]
      socket.write(Monk::WebSocket::Frame.encode(frame[:payload], opcode: 0xA))
    end
  ensure
    socket&.close
  end

  # Any frame counts, not only a pong: a client that keeps sending messages
  # and ignores the pings isn't silent.
  def test_any_frame_from_the_client_keeps_it_open
    server = start_server(ping_interval: 0.05, &WAIT_FOR_DISCONNECT)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)
    sender = Thread.new do
      loop do
        socket.write(Monk::WebSocket::Frame.encode("hi", opcode: 0x1))
        sleep 0.03
      end
    end

    sleep 0.5
    assert_equal 0x9, read_raw_frame(socket)[:opcode], "expected the connection still open"
  ensure
    sender&.kill
    socket&.close
  end

  # The case that rules out pinging through the write mutex: a writer
  # blocked on a full send buffer holds it, and the heartbeat must still
  # reach its deadline and shut the socket, which ends that write too.
  def test_a_silent_client_is_closed_even_while_a_write_to_it_is_blocked
    server = start_server(ping_interval: 0.05, &FLOOD)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)
    wait_until { FLOOD_REGISTRY.count(:flood) == 1 }

    wait_until(timeout: 2) { FLOOD_REGISTRY.count(:flood).zero? }
  ensure
    socket&.close
  end

  # Seen on a phone that turned Wi-Fi off: the next ping's write raised
  # Errno::EHOSTDOWN (macOS; Linux has EHOSTUNREACH), which ended the
  # heartbeat thread, and with it the close after two silent intervals.
  def test_a_ping_failing_with_a_network_error_still_closes_a_silent_peer
    server_side, client = UNIXSocket.pair
    failures = [Errno::EHOSTDOWN]
    server_side.define_singleton_method(:write_nonblock) do |*args, **kwargs|
      error = failures.shift
      raise error if error

      super(*args, **kwargs)
    end
    connection = Monk::WebSocket::Connection.new(server_side)
    connection.start_heartbeat(0.05)

    waiter = Thread.new { read_frame_or_eof(client) }
    assert waiter.join(1), "expected the silent peer closed after two intervals"
    assert_nil waiter.value
  ensure
    waiter&.kill
    connection&.stop_heartbeat!
    server_side&.close
    client&.close
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

  # The next frame, or nil once the server has closed the socket.
  def read_frame_or_eof(socket)
    read_raw_frame(socket)
  rescue Errno::ECONNRESET, IOError
    nil
  end

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
