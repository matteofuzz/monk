module Monk
  module WebSocket
    # Monk's Context-equivalent for a WS connection (docs/history/plan-websocket.md step
    # 10): the socket and frame machinery are never exposed directly to app
    # code. Lives entirely inside its own connection Ractor -- never itself
    # crosses a Ractor boundary, so it needs no shareability of its own.
    class Connection
      # 1 MiB -- generous for chat-sized text, cheap insurance against a
      # hostile length claim on a public endpoint (gap 5,
      # docs/history/chat-gap-analysis.md). Enforced twice: against a single
      # frame's declared length (#read_frame, before the payload is ever
      # read off the wire) and against a fragmented message's reassembled
      # total (#read) -- otherwise chunking a message into many frames
      # each just under the per-frame cap would silently bypass it.
      DEFAULT_MAX_PAYLOAD_SIZE = 1 * 1024 * 1024

      # With a heartbeat (#start_heartbeat), a connection that sends
      # nothing for this many ping intervals is taken for gone and closed:
      # one ping unanswered is allowed, two aren't.
      IDLE_PINGS = 2

      # subject is whatever Monk::Auth.verify returned when
      # Server.new(authenticate: true) verified this handshake
      # (docs/history/plan-websocket.md Phase 5) -- nil for an unauthenticated server.
      attr_reader :subject

      def self.monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # presence: is a Monk::Presence::Counts this connection reports to
      # (Server.new(presence:)), used only for a connection with a subject.
      def initialize(socket, subject: nil, max_payload_size: DEFAULT_MAX_PAYLOAD_SIZE, presence: nil)
        @socket = socket
        @subject = subject
        @presence = presence if subject
        @write_mutex = Mutex.new
        @max_payload_size = max_payload_size
        @last_read_at = Connection.monotonic
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
            # A pong: read_frame has already noted that the peer is
            # there (#start_heartbeat's idle deadline), and it's not a
            # message for app code.
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
      # end the connection -- no wait for the client's own close frame in
      # reply.
      #
      # Shut down, not closed: this runs from other threads too (a relay
      # on Registry#close_all, the reverify thread) while the handler's
      # thread is blocked reading. IO#close would wait for that reader,
      # and the reader's cleanup kills the closing thread mid-close,
      # leaving the descriptor open: the client never sees the close.
      # shutdown tells the client at once and ends the blocked read (it
      # returns nil, as on any disconnect); Server.serve's ensure closes
      # the socket.
      def close(code: 1000, reason: "")
        write_frame([code].pack("n") + reason.to_s, 0x8)
        @socket.shutdown(:RDWR)
      rescue Errno::ENOTCONN
        # The client went away first: nothing left to shut down.
      end

      # Registers this connection's own Ractor::Port -- the "connection
      # handle" a Monk::WebSocket::Registry holds (docs/history/plan-websocket.md step
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
      # docs/history/chat-gap-analysis.md): answering a client's own ping keeps a
      # connection alive only if the client ever sends one, and browser
      # JavaScript has no API to send WS ping frames at all -- so a truly
      # idle browser connection still gets dropped by a reverse proxy's
      # idle timeout without this. A spec-compliant client (including
      # every browser's own WebSocket implementation, transparently, with
      # no app-level JS involved) answers a server-sent ping with a pong
      # automatically; #read already discards an incoming pong silently
      # either way, so nothing app-visible changes.
      #
      # The same thread closes a connection that has sent nothing, not even
      # a pong, for IDLE_PINGS intervals (docs/plan-live-networks-presence.md,
      # A1): a peer that vanished without a FIN or an RST (a phone that
      # changed network) never ends the read on its own. With nothing to
      # send, the kernel never notices; with a ping pending, Linux gives up
      # after about 15 minutes. It sleeps until the earlier of its next ping
      # and that deadline, so the close comes at IDLE_PINGS intervals, not
      # up to one more.
      def start_heartbeat(interval)
        idle_timeout = interval * IDLE_PINGS
        @heartbeat_thread = Thread.new do
          next_ping = Connection.monotonic + interval
          loop do
            now = Connection.monotonic
            deadline = @last_read_at + idle_timeout
            break drop_silent_peer if now >= deadline

            if now >= next_ping
              send_ping
              @on_heartbeat&.call
              next_ping = now + interval
            end
            sleep [[next_ping, deadline].min - Connection.monotonic, 0].max
          end
        rescue IOError, Errno::EPIPE, Errno::ECONNRESET
          # The socket closed out from under this loop -- #close or a
          # real disconnect racing the next scheduled ping. #stop_heartbeat!
          # still runs from Server.serve's ensure regardless; this just
          # keeps the thread from surfacing the expected teardown race as
          # a Thread.report_on_exception warning.
        end
      end

      # A block run on the heartbeat thread after each ping, in this
      # connection's Ractor: periodic work for a handler without a thread
      # of its own per connection (Live::Session's check for a silent
      # page). Never runs without ping_interval:.
      def on_heartbeat(&block)
        @on_heartbeat = block
      end

      # Called unconditionally from Server.serve's ensure, alongside
      # #unsubscribe! -- a no-op if #start_heartbeat was never called.
      def stop_heartbeat!
        @heartbeat_thread&.kill
      end

      # Presence (docs/adr/0019-...): whether this connection is counted
      # for its subject. Server.serve reports the open after the 101 and
      # the close in its ensure; a handler that knows whether its page is
      # visible (Live::Session, from its client's pings) sets #visible=.
      # Each is a send to the counts, never a wait, keyed by this
      # connection's own Ractor.
      def tracks_presence? = !@presence.nil?

      def presence_open!
        @presence&.open(Ractor.current, @subject.to_s)
      end

      def presence_close!
        @presence&.close(Ractor.current)
      end

      # Reported only when it changes.
      def visible=(visible)
        return if @visible == visible

        @visible = visible
        @presence&.visible(Ractor.current, visible)
      end

      private

      # A ping that can't go out at once is skipped, not waited for: on a
      # dead connection the kernel's send buffer fills, a writer (a relay
      # with patches queued) blocks inside write_frame holding the mutex,
      # and a heartbeat waiting behind it would never reach its deadline.
      # A ping cut in half (the buffer had room for one byte) would corrupt
      # the stream, so that connection is dropped instead.
      #
      # A ping that fails with a network error (Errno::EHOSTDOWN on macOS,
      # EHOSTUNREACH on Linux, once the peer's network is gone) is skipped
      # too: ending the heartbeat there would also end the close after
      # IDLE_PINGS silent intervals, the one thing that still frees a
      # connection whose peer vanished. A closed socket (IOError) still
      # ends it.
      def send_ping
        return unless @write_mutex.try_lock

        begin
          ping = Monk::WebSocket::Frame.encode("", opcode: 0x9)
          written = @socket.write_nonblock(ping, exception: false)
          drop_silent_peer if written.is_a?(Integer) && written < ping.bytesize
        rescue SystemCallError
          # Skipped; the deadline decides.
        ensure
          @write_mutex.unlock
        end
      end

      # Shut down, without a close frame and without the write mutex: the
      # peer is taken for gone, and a writer may be blocked holding the
      # mutex on its full send buffer. shutdown makes that write raise and
      # the handler's read return nil, and Server.serve's ensure cleans up
      # as after any other close.
      def drop_silent_peer
        @socket.shutdown(:RDWR)
      rescue IOError, SystemCallError
        # Already closed or gone.
      end

      def relay_broadcasts
        loop do
          message = @port.receive
          next write(message) unless message.is_a?(CloseRequest)

          # Registry#close_all: the read loop then sees the socket closed
          # and Server.serve's cleanup runs as on any other close.
          return close(code: message.code, reason: message.reason)
        end
      rescue Ractor::ClosedError, IOError, SystemCallError
        # #unsubscribe! closed the port out from under a pending #receive,
        # or the socket went away first.
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

        # Any frame shows the peer is there: data, a ping, a pong.
        @last_read_at = Connection.monotonic
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
