module Monk
  module WebSocket
    # Monk's Context-equivalent for a WS connection (PLAN-WEBSOCKET.md step
    # 10): the socket and frame machinery are never exposed directly to app
    # code. Lives entirely inside its own connection Ractor -- never itself
    # crosses a Ractor boundary, so it needs no shareability of its own.
    class Connection
      # 1 MiB -- generous for chat-sized text, cheap insurance against a
      # hostile length claim on a public endpoint (gap 5,
      # docs/chat-gap-analysis.md). Enforced twice: against a single
      # frame's declared length (#read_frame, before the payload is ever
      # read off the wire) and against a fragmented message's reassembled
      # total (#read) -- otherwise chunking a message into many frames
      # each just under the per-frame cap would silently bypass it.
      DEFAULT_MAX_PAYLOAD_SIZE = 1 * 1024 * 1024

      # subject is whatever Monk::Auth.verify returned when
      # Server.new(authenticate: true) verified this handshake
      # (PLAN-WEBSOCKET.md Phase 5) -- nil for an unauthenticated server.
      attr_reader :subject

      def initialize(socket, subject: nil, max_payload_size: DEFAULT_MAX_PAYLOAD_SIZE)
        @socket = socket
        @subject = subject
        @write_mutex = Mutex.new
        @max_payload_size = max_payload_size
      end

      # Reassembles a fragmented message per RFC 6455 5.4: a frame with
      # fin: false starts one, opcode 0x0 continues it, and the frame
      # carrying fin: true ends it. Previously `fin` was decoded and then
      # ignored entirely, so a continuation frame fell straight through
      # the `else` branch below and reached app code as if it were its
      # own complete message (gap 5). A continuation frame with nothing
      # to continue, or a new fragmented message started before the
      # current one finished, are both protocol violations -- closed with
      # 1002 rather than silently misinterpreted.
      def read
        fragments = nil
        fragments_size = 0

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
          when 0x0
            return close_with(1002, "unexpected continuation frame") unless fragments

            fragments << frame[:payload]
            fragments_size += frame[:payload].bytesize
            return close_with(1009, "message too large") if fragments_size > @max_payload_size

            return fragments.join if frame[:fin]
          else
            return close_with(1002, "expected a continuation frame") if fragments
            return frame[:payload] if frame[:fin]

            fragments = [frame[:payload]]
            fragments_size = frame[:payload].bytesize
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

      # Sends an unsolicited ping frame every `interval` seconds for as
      # long as the connection stays open (gap 3,
      # docs/chat-gap-analysis.md): answering a client's own ping keeps a
      # connection alive only if the client ever sends one, and browser
      # JavaScript has no API to send WS ping frames at all -- so a truly
      # idle browser connection still gets dropped by a reverse proxy's
      # idle timeout without this. A spec-compliant client (including
      # every browser's own WebSocket implementation, transparently, with
      # no app-level JS involved) answers a server-sent ping with a pong
      # automatically; #read already discards an incoming pong silently
      # either way, so nothing app-visible changes.
      def start_heartbeat(interval)
        @heartbeat_thread = Thread.new do
          loop do
            sleep interval
            write("", opcode: 0x9)
          end
        rescue IOError, Errno::EPIPE, Errno::ECONNRESET
          # The socket closed out from under this loop -- #close or a
          # real disconnect racing the next scheduled ping. #stop_heartbeat!
          # still runs from Server.serve's ensure regardless; this just
          # keeps the thread from surfacing the expected teardown race as
          # a Thread.report_on_exception warning.
        end
      end

      # Called unconditionally from Server.serve's ensure, alongside
      # #unsubscribe! -- a no-op if #start_heartbeat was never called.
      def stop_heartbeat!
        @heartbeat_thread&.kill
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

      # Sends a close frame carrying `code`/`reason`, closes the socket,
      # and returns nil -- the shared exit path for both gap-5 violations
      # (an oversized declared length, an out-of-sequence fragment),
      # always returned via `return close_with(...)` so the nil correctly
      # propagates out of #read the same way any other disconnect does.
      def close_with(code, reason)
        write_frame([code].pack("n") + reason, 0x8)
        @socket.close
        nil
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
        # Checked before the payload is read off the wire, not after --
        # the whole point is to never attempt to buffer a hostile
        # multi-gigabyte claim in the first place (gap 5).
        return close_with(1009, "payload too large") if length > @max_payload_size

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
