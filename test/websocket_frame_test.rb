require_relative "test_helper"
require "monk/websocket"

class WebSocketFrameTest < Minitest::Test
  # RFC 6455 section 5.7's own worked example: a single-frame masked text
  # message "Hello" from a client.
  def test_decode_a_masked_7_bit_length_frame
    bytes = [0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58].pack("C*")

    frame = Monk::WebSocket::Frame.decode(bytes)

    assert_equal true, frame[:fin]
    assert_equal 0x1, frame[:opcode]
    assert_equal true, frame[:masked]
    assert_equal "Hello", frame[:payload]
  end

  # RFC 6455 section 5.7's server-to-client counterpart: server frames are
  # never masked.
  def test_decode_an_unmasked_7_bit_length_frame
    bytes = [0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f].pack("C*")

    frame = Monk::WebSocket::Frame.decode(bytes)

    assert_equal false, frame[:masked]
    assert_equal "Hello", frame[:payload]
  end

  def test_decode_a_16_bit_extended_length_frame
    payload = "a" * 300
    bytes = [0x82, 0x7E].pack("C2") + [payload.bytesize].pack("n") + payload

    frame = Monk::WebSocket::Frame.decode(bytes)

    assert_equal 0x2, frame[:opcode]
    assert_equal false, frame[:masked]
    assert_equal payload, frame[:payload]
  end

  def test_decode_a_64_bit_extended_length_frame
    payload = "b" * 70_000
    bytes = [0x82, 0x7F].pack("C2") + [payload.bytesize].pack("Q>") + payload

    frame = Monk::WebSocket::Frame.decode(bytes)

    assert_equal 0x2, frame[:opcode]
    assert_equal payload, frame[:payload]
  end

  # RFC 6455 section 5.7's server-to-client example, byte-for-byte.
  def test_encode_a_7_bit_length_frame
    bytes = Monk::WebSocket::Frame.encode("Hello", opcode: 0x1)

    assert_equal [0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f].pack("C*"), bytes
  end

  def test_encode_a_16_bit_extended_length_frame
    payload = "a" * 300

    bytes = Monk::WebSocket::Frame.encode(payload, opcode: 0x2)

    assert_equal [0x82, 0x7E].pack("C2") + [300].pack("n") + payload, bytes
  end

  def test_encode_a_64_bit_extended_length_frame
    payload = "b" * 70_000

    bytes = Monk::WebSocket::Frame.encode(payload, opcode: 0x2)

    assert_equal [0x82, 0x7F].pack("C2") + [70_000].pack("Q>") + payload, bytes
  end

  def test_encode_then_decode_round_trips
    payload = "round trip"

    frame = Monk::WebSocket::Frame.decode(Monk::WebSocket::Frame.encode(payload, opcode: 0x1))

    assert_equal payload, frame[:payload]
    assert_equal false, frame[:masked]
    assert_equal true, frame[:fin]
  end

  def test_decode_raises_protocol_error_on_a_too_short_header
    assert_raises(Monk::WebSocket::ProtocolError) { Monk::WebSocket::Frame.decode([0x81].pack("C")) }
  end

  def test_decode_raises_protocol_error_when_extended_length_bytes_are_missing
    bytes = [0x82, 0x7E, 0x01].pack("C3") # says "16-bit length follows" but only gives 1 more byte

    assert_raises(Monk::WebSocket::ProtocolError) { Monk::WebSocket::Frame.decode(bytes) }
  end

  def test_decode_raises_protocol_error_when_mask_key_is_missing
    bytes = [0x81, 0x85].pack("C2") # masked bit set, but no mask key or payload follows

    assert_raises(Monk::WebSocket::ProtocolError) { Monk::WebSocket::Frame.decode(bytes) }
  end

  def test_decode_raises_protocol_error_when_payload_is_shorter_than_declared_length
    bytes = [0x81, 0x05].pack("C2") + "ab" # declares a 5-byte payload, gives 2

    assert_raises(Monk::WebSocket::ProtocolError) { Monk::WebSocket::Frame.decode(bytes) }
  end

  def test_decode_recognizes_close_ping_and_pong_opcodes
    { close: 0x8, ping: 0x9, pong: 0xA }.each do |name, opcode|
      frame = Monk::WebSocket::Frame.decode(Monk::WebSocket::Frame.encode("", opcode: opcode))

      assert_equal opcode, frame[:opcode], "expected #{name} (#{opcode}) to round-trip"
    end
  end
end
