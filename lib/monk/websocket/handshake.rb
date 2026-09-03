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

      # PLAN-WEBSOCKET.md step 21: (a) Authorization: Bearer -- the
      # non-browser/S2S path -- takes priority; (b) otherwise the
      # session_token cookie, arriving automatically because cookies
      # aren't port-scoped. Mirrors Monk::Auth::Helpers' identical
      # bearer_token/session_cookie_token logic, reimplemented here since
      # this runs from parsed handshake headers, not a Context.
      def self.credential_from(headers)
        if (token = bearer_token(headers))
          { token: token, via: :bearer }
        elsif (token = session_cookie_token(headers))
          { token: token, via: :cookie }
        end
      end

      def self.bearer_token(headers)
        auth_header = headers["authorization"]
        return nil unless auth_header&.start_with?("Bearer ")

        token = auth_header.delete_prefix("Bearer ")
        token.empty? ? nil : token
      end
      private_class_method :bearer_token

      def self.session_cookie_token(headers)
        headers["cookie"].to_s.split(";").each_with_object({}) do |pair, cookies|
          name, value = pair.strip.split("=", 2)
          cookies[name] = value if name
        end["session_token"]
      end
      private_class_method :session_cookie_token

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
