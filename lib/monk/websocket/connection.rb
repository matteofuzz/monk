module Monk
  module WebSocket
    # Monk's Context-equivalent for a WS connection (PLAN-WEBSOCKET.md step
    # 10): the socket and frame machinery are never exposed directly to app
    # code. Lives entirely inside its own connection Ractor -- never itself
    # crosses a Ractor boundary, so it needs no shareability of its own.
    class Connection
      def initialize(socket)
        @socket = socket
      end

      def read
        header = read_exactly(2)
        return nil unless header

        byte1 = header.getbyte(1)
        masked = byte1.anybits?(0x80)
        length_indicator = byte1 & 0x7F

        extended =
          case length_indicator
          when 126 then read_exactly(2)
          when 127 then read_exactly(8)
          else ""
          end
        return nil if extended.nil?

        mask_key = masked ? read_exactly(4) : ""
        return nil if mask_key.nil?

        length = extended_length(length_indicator, extended)
        payload = read_exactly(length)
        return nil unless payload

        Monk::WebSocket::Frame.decode(header + extended + mask_key + payload)[:payload]
      end

      def write(payload, opcode: 0x1)
        @socket.write(Monk::WebSocket::Frame.encode(payload, opcode: opcode))
      end

      private

      def extended_length(length_indicator, extended)
        case length_indicator
        when 126 then extended.unpack1("n")
        when 127 then extended.unpack1("Q>")
        else length_indicator
        end
      end

      def read_exactly(n)
        return "" if n.zero?

        data = @socket.read(n)
        return nil if data.nil? || data.bytesize < n

        data
      end
    end
  end
end
