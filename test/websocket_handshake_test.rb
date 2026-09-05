require_relative "test_helper"
require "monk/websocket"

class WebSocketHandshakeTest < Minitest::Test
  # The exact worked example from RFC 6455 section 1.3.
  def test_accept_key_computes_the_rfc6455_example
    assert_equal "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
      Monk::WebSocket::Handshake.accept_key("dGhlIHNhbXBsZSBub25jZQ==")
  end

  VALID_REQUEST = <<~REQ.gsub("\n", "\r\n")
    GET /chat HTTP/1.1
    Host: server.example.com
    Upgrade: websocket
    Connection: Upgrade
    Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
    Sec-WebSocket-Version: 13

  REQ

  def test_parse_request_extracts_headers_lowercased
    headers = Monk::WebSocket::Handshake.parse_request(VALID_REQUEST)

    assert_equal "dGhlIHNhbXBsZSBub25jZQ==", headers["sec-websocket-key"]
    assert_equal "server.example.com", headers["host"]
  end

  def test_parse_request_raises_on_missing_upgrade_header
    request = VALID_REQUEST.sub("Upgrade: websocket\r\n", "")

    error = assert_raises(Monk::WebSocket::HandshakeError) do
      Monk::WebSocket::Handshake.parse_request(request)
    end
    assert_match(/upgrade/i, error.message)
  end

  def test_parse_request_raises_on_wrong_upgrade_value
    request = VALID_REQUEST.sub("Upgrade: websocket", "Upgrade: h2c")

    assert_raises(Monk::WebSocket::HandshakeError) do
      Monk::WebSocket::Handshake.parse_request(request)
    end
  end

  def test_parse_request_raises_on_missing_connection_header
    request = VALID_REQUEST.sub("Connection: Upgrade\r\n", "")

    error = assert_raises(Monk::WebSocket::HandshakeError) do
      Monk::WebSocket::Handshake.parse_request(request)
    end
    assert_match(/connection/i, error.message)
  end

  def test_parse_request_raises_on_missing_sec_websocket_key
    request = VALID_REQUEST.sub("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n", "")

    error = assert_raises(Monk::WebSocket::HandshakeError) do
      Monk::WebSocket::Handshake.parse_request(request)
    end
    assert_match(/sec-websocket-key/i, error.message)
  end

  def test_response_for_builds_the_101_switching_protocols_response
    response = Monk::WebSocket::Handshake.response_for(VALID_REQUEST)

    assert_equal(
      "HTTP/1.1 101 Switching Protocols\r\n" \
      "Upgrade: websocket\r\n" \
      "Connection: Upgrade\r\n" \
      "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" \
      "\r\n",
      response,
    )
  end

  def test_credential_from_prefers_a_bearer_header_over_a_cookie
    headers = { "authorization" => "Bearer abc123", "cookie" => "session_token=xyz789" }

    assert_equal({ token: "abc123", via: :bearer }, Monk::WebSocket::Handshake.credential_from(headers))
  end

  def test_credential_from_falls_back_to_the_session_cookie
    headers = { "cookie" => "other=1; session_token=xyz789; foo=bar" }

    assert_equal({ token: "xyz789", via: :cookie }, Monk::WebSocket::Handshake.credential_from(headers))
  end

  def test_credential_from_returns_nil_when_neither_is_present
    assert_nil Monk::WebSocket::Handshake.credential_from({})
  end

  def test_credential_from_ignores_a_malformed_bearer_header
    headers = { "authorization" => "sometoken", "cookie" => "session_token=xyz789" }

    assert_equal({ token: "xyz789", via: :cookie }, Monk::WebSocket::Handshake.credential_from(headers))
  end
end
