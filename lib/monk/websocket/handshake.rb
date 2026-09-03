require "digest"
require "base64"

module Monk
  module WebSocket
    module Handshake
      # An unfrozen constant here is exactly the bug Phase 0's spike hit
      # (docs/websocket.md) -- Ractor::IsolationError the first time this is
      # read from a connection Ractor. .freeze is not optional.
      MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11".freeze

      def self.accept_key(client_key)
        Base64.strict_encode64(Digest::SHA1.digest(client_key + MAGIC))
      end

      def self.parse_request(raw_request)
        headers = raw_request.split("\r\n").drop(1).each_with_object({}) do |line, h|
          next if line.empty?

          name, value = line.split(":", 2)
          h[name.strip.downcase] = value.strip if name && value
        end

        unless headers["upgrade"]&.downcase == "websocket"
          raise Monk::WebSocket::HandshakeError, "missing or invalid Upgrade header"
        end
        unless headers["connection"]&.downcase&.split(/\s*,\s*/)&.include?("upgrade")
          raise Monk::WebSocket::HandshakeError, "missing or invalid Connection header"
        end
        raise Monk::WebSocket::HandshakeError, "missing Sec-WebSocket-Key header" unless headers["sec-websocket-key"]

        headers
      end

      def self.response_for(raw_request)
        headers = parse_request(raw_request)

        "HTTP/1.1 101 Switching Protocols\r\n" \
        "Upgrade: websocket\r\n" \
        "Connection: Upgrade\r\n" \
        "Sec-WebSocket-Accept: #{accept_key(headers["sec-websocket-key"])}\r\n" \
        "\r\n"
      end
    end
  end
end
