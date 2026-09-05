module Monk
  module WebSocket
    module Frame
      def self.decode(bytes)
        raise Monk::WebSocket::ProtocolError, "frame header too short" if bytes.bytesize < 2

        byte0, byte1 = bytes.unpack("C2")
        fin = byte0.anybits?(0x80)
        opcode = byte0 & 0x0F
        masked = byte1.anybits?(0x80)
        length = byte1 & 0x7F

        offset = 2
        case length
        when 126
          require_bytes!(bytes, offset, 2, "extended 16-bit length")
          length = bytes[offset, 2].unpack1("n")
          offset += 2
        when 127
          require_bytes!(bytes, offset, 8, "extended 64-bit length")
          length = bytes[offset, 8].unpack1("Q>")
          offset += 8
        end

        if masked
          require_bytes!(bytes, offset, 4, "mask key")
          mask_key = bytes[offset, 4]
          offset += 4
        end

        require_bytes!(bytes, offset, length, "payload")
        payload = bytes[offset, length]
        payload = unmask(payload, mask_key) if masked

        { fin: fin, opcode: opcode, masked: masked, payload: payload }
      end

      def self.require_bytes!(bytes, offset, needed, what)
        return if bytes.bytesize - offset >= needed

        raise Monk::WebSocket::ProtocolError, "truncated frame: #{what} missing or incomplete"
      end
      private_class_method :require_bytes!

      # Server frames are never masked, per RFC 6455 -- masking is a
      # client-to-server-only requirement.
      def self.encode(payload, opcode:)
        byte0 = 0x80 | opcode

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

      def self.unmask(payload, mask_key)
        payload.each_byte.with_index.map { |byte, i| byte ^ mask_key.getbyte(i % 4) }.pack("C*")
      end
      private_class_method :unmask
    end
  end
end
