require "digest"
require "base64"

module Monk
  module WebSocket
    module Handshake
      # An unfrozen constant here is exactly the bug Phase 0's spike hit
      # (docs/design/websocket.md) -- Ractor::IsolationError the first time this is
      # read from a connection Ractor. .freeze is not optional.
      MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11".freeze

      # The most a handshake request's head may be (Server.serve answers
      # 431 past it): room for a large cookie, nowhere near a memory risk.
      MAX_REQUEST_SIZE = 16 * 1024

      def self.accept_key(client_key)
        Base64.strict_encode64(Digest::SHA1.digest(client_key + MAGIC))
      end

      # Two Strings a header line (its name and its value), plus the line:
      # this runs once a connect, and every object it makes is one more
      # towards the next GC (docs/plan-ws-connect-ceiling.md, item 4).
      def self.parse_request(raw_request)
        headers = {}
        request_line = true
        raw_request.each_line("\r\n", chomp: true) do |line|
          if request_line
            request_line = false
            next
          end

          colon = line.index(":")
          next unless colon

          name = line.byteslice(0, colon)
          name.strip!
          name.downcase!
          value = line.byteslice(colon + 1, line.bytesize)
          value.strip!
          headers[name] = value
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

      # docs/history/plan-websocket.md step 21: (a) Authorization: Bearer -- the
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

      # The last session_token in the header wins, as when it was a Hash.
      def self.session_cookie_token(headers)
        token = nil
        headers["cookie"]&.split(";")&.each do |pair|
          name, value = pair.strip.split("=", 2)
          token = value if name == "session_token"
        end
        token
      end
      private_class_method :session_cookie_token

      def self.response_for(raw_request) = response(parse_request(raw_request))

      # The 101 for headers parse_request already returned.
      def self.response(headers)
        "HTTP/1.1 101 Switching Protocols\r\n" \
        "Upgrade: websocket\r\n" \
        "Connection: Upgrade\r\n" \
        "Sec-WebSocket-Accept: #{accept_key(headers["sec-websocket-key"])}\r\n" \
        "\r\n"
      end
    end
  end
end
