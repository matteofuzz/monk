require_relative "test_helper"
require "monk/websocket"
require "socket"

class WebSocketFragmentationTest < Minitest::Test
  include WebSocketTestHelpers

  # Defined at class-body scope -- see websocket_server_test.rb's comment
  # on ECHO_ONE_MESSAGE for why.
  ECHO_ONE_MESSAGE = proc do |connection|
    message = connection.read
    connection.write(message) if message
  end

  # Frame.encode always sets fin: true (correct for the server, which
  # never fragments its own frames) -- these tests need to act as a
  # client sending fragmented/malformed frames instead, so this builds
  # the header by hand rather than going through Frame.encode.
  def encode_frame(payload, opcode:, fin: true)
    byte0 = (fin ? 0x80 : 0x00) | opcode
    length_bytes =
      if payload.bytesize <= 125
        [payload.bytesize].pack("C")
      elsif payload.bytesize <= 0xFFFF
        [126].pack("C") + [payload.bytesize].pack("n")
      else
        [127].pack("C") + [payload.bytesize].pack("Q>")
      end
    [byte0].pack("C") + length_bytes + payload
  end

  # A header claiming `claimed_length` bytes follow, with no payload
  # bytes actually written -- used to prove the oversized-length check
  # happens before the server ever attempts to read that many bytes.
  def oversized_header(claimed_length)
    [0x82, 0x7F].pack("C2") + [claimed_length].pack("Q>")
  end

  def close_code(frame)
    frame[:payload][0, 2].unpack1("n")
  end

  # No non-blocking read on a raw socket, so bound the wait instead of
  # risking a hang if a regression reintroduces the "block forever
  # reading a hostile length" bug this test exists to catch.
  def read_raw_frame_with_timeout(socket, timeout: 1.0)
    frame = nil
    waiter = Thread.new { frame = read_raw_frame(socket) }
    completed = waiter.join(timeout)
    waiter.kill unless completed
    flunk "expected a frame within #{timeout}s, got none (socket blocked?)" unless completed
    frame
  end

  def test_a_fragmented_text_message_is_reassembled_before_reaching_the_handler
    server = start_server(&ECHO_ONE_MESSAGE)
    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)

    socket.write(encode_frame("hel", opcode: 0x1, fin: false))
    socket.write(encode_frame("lo ", opcode: 0x0, fin: false))
    socket.write(encode_frame("world", opcode: 0x0, fin: true))

    assert_equal "hello world", read_frame(socket)
  ensure
    socket&.close
  end

  def test_a_single_frame_binary_message_with_fin_true_is_unaffected
    server = start_server(&ECHO_ONE_MESSAGE)
    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)

    socket.write(encode_frame("not fragmented", opcode: 0x2, fin: true))

    assert_equal "not fragmented", read_frame(socket)
  ensure
    socket&.close
  end

  def test_an_orphan_continuation_frame_closes_with_protocol_error
    server = start_server(&ECHO_ONE_MESSAGE)
    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)

    socket.write(encode_frame("nothing to continue", opcode: 0x0, fin: true))

    frame = read_raw_frame_with_timeout(socket)
    assert_equal 0x8, frame[:opcode]
    assert_equal 1002, close_code(frame)
  ensure
    socket&.close
  end

  def test_starting_a_new_message_before_finishing_the_current_fragment_closes_with_protocol_error
    server = start_server(&ECHO_ONE_MESSAGE)
    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)

    socket.write(encode_frame("first", opcode: 0x1, fin: false))
    socket.write(encode_frame("second", opcode: 0x1, fin: false))

    frame = read_raw_frame_with_timeout(socket)
    assert_equal 0x8, frame[:opcode]
    assert_equal 1002, close_code(frame)
  ensure
    socket&.close
  end

  def test_a_frame_claiming_a_length_over_the_cap_is_rejected_before_the_payload_is_read
    server = start_server(max_payload_size: 100, &ECHO_ONE_MESSAGE)
    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)

    # Only the header is sent -- no payload bytes at all. If the server
    # tried to read the claimed length before checking the cap, this
    # would hang instead of closing.
    socket.write(oversized_header(100_000))

    frame = read_raw_frame_with_timeout(socket)
    assert_equal 0x8, frame[:opcode]
    assert_equal 1009, close_code(frame)
  ensure
    socket&.close
  end

  def test_a_reassembled_fragmented_message_over_the_cap_is_rejected_even_though_each_frame_is_under_it
    server = start_server(max_payload_size: 10, &ECHO_ONE_MESSAGE)
    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)

    socket.write(encode_frame("123456", opcode: 0x1, fin: false)) # 6 bytes, under the 10-byte cap alone
    socket.write(encode_frame("7890ab", opcode: 0x0, fin: true))  # 6 more -- 12 total, over the cap

    frame = read_raw_frame_with_timeout(socket)
    assert_equal 0x8, frame[:opcode]
    assert_equal 1009, close_code(frame)
  ensure
    socket&.close
  end

  def test_max_payload_size_must_be_positive
    error = assert_raises(ArgumentError) { Monk::WebSocket::Server.new(port: 0, max_payload_size: 0) }
    assert_match(/max_payload_size/, error.message)
  end
end
