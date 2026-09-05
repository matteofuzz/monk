module Monk
  module WebSocket
    # Monk's Context-equivalent for a WS connection (PLAN-WEBSOCKET.md step
    # 10): the socket and frame machinery are never exposed directly to app
    # code. Lives entirely inside its own connection Ractor -- never itself
    # crosses a Ractor boundary, so it needs no shareability of its own.
    class Connection
      # subject is whatever Monk::Auth.verify returned when
      # Server.new(authenticate: true) verified this handshake
      # (PLAN-WEBSOCKET.md Phase 5) -- nil for an unauthenticated server.
      attr_reader :subject

      def initialize(socket, subject: nil)
        @socket = socket
        @subject = subject
        @write_mutex = Mutex.new
      end

      def read
        loop do
          frame = read_frame
          return nil unless frame

          case frame[:opcode]
          when 0x8
            # The RFC 6455 closing handshake, not a bare TCP close (step
            # 13): echo a close frame back, close the socket, and report
            # this to app code the same way any other disconnect is
            # reported -- #read returning nil (step 15).
            write_frame(frame[:payload], 0x8)
            @socket.close
            return nil
          when 0x9
            # Answered automatically, without reaching app code (step
            # 24): keeps a long-lived authenticated connection alive
            # through idle reverse-proxy timeouts. Echoes the ping's own
            # payload back, per RFC 6455 5.5.3.
            write_frame(frame[:payload], 0xA)
          when 0xA
            # An unsolicited pong -- nothing to do yet (no pending-ping
            # tracking exists), but still not a message for app code.
          else
            return frame[:payload]
          end
        end
      end

      def write(payload, opcode: 0x1)
        write_frame(payload, opcode)
      end

      # The server-initiated close path (step 14): send a close frame
      # carrying the 2-byte status code + reason RFC 6455 expects, then
      # close the socket outright -- no wait for the client's own close
      # frame in reply.
      def close(code: 1000, reason: "")
        write_frame([code].pack("n") + reason.to_s, 0x8)
        @socket.close
      end

      # Registers this connection's own Ractor::Port -- the "connection
      # handle" a Monk::WebSocket::Registry holds (PLAN-WEBSOCKET.md step
      # 17) -- under key, and relays whatever the registry broadcasts onto
      # this socket via a background Thread inside this connection's own
      # Ractor (safe: a Ractor may freely spawn ordinary Threads within
      # itself, same as the main Ractor already does elsewhere in Monk).
      def subscribe(registry, key)
        @registry = registry
        @key = key
        @port = Ractor::Port.new
        registry.register(key, @port)
        @relay_thread = Thread.new { relay_broadcasts }
      end

      # Called unconditionally from Server.serve's ensure on every exit
      # path -- normal completion, the close handshake, and a crashed
      # handler alike -- so a subscribed connection never leaves a stale
      # entry in the registry (step 17). A no-op if #subscribe was never
      # called.
      def unsubscribe!
        return unless @registry

        @relay_thread.kill
        @registry.unregister(@key, @port)
        @port.close
      end

      private

      def relay_broadcasts
        loop { write(@port.receive) }
      rescue Ractor::ClosedError
        # #unsubscribe! closed the port out from under a pending #receive.
      end

      def write_frame(payload, opcode)
        @write_mutex.synchronize { @socket.write(Monk::WebSocket::Frame.encode(payload, opcode: opcode)) }
      end

      def read_frame
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

        Monk::WebSocket::Frame.decode(header + extended + mask_key + payload)
      end

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
