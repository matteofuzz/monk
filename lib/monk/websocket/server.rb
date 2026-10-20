require "socket"

module Monk
  module WebSocket
    # Intended to be the entire body of a small standalone script (e.g.
    # bin/websocket_server) -- never embedded in the same process as Kino
    # (docs/history/plan-websocket.md Decision 1).
    class Server
      # allowed_origins: and authenticate: implement docs/history/plan-websocket.md
      # Phase 5 (identity via Monk::Auth, reused unmodified -- Decision
      # 5). authenticate: defaults false so a plain server (Phases 1-4)
      # behaves exactly as before; turning it on requires Monk::Auth to
      # already be configured, fail-fast the same way Monk::Auth's own
      # methods do (ADR 0003) rather than failing obscurely on the first
      # connection.
      #
      # ping_interval: (seconds) opts a connection into a server-sent
      # heartbeat ping -- see Connection#start_heartbeat. Defaults to nil
      # (disabled) for the same reason authenticate: defaults false: a
      # server that doesn't ask for it behaves exactly as before.
      #
      # reverify_interval: (seconds) re-runs Monk::Auth.verify against the
      # same credential on that cadence for as long as the connection
      # stays open, closing it the moment verify comes back nil (gap 4,
      # docs/history/chat-gap-analysis.md) -- authenticate: true only checks the
      # credential once, at the handshake, so a session revoked or
      # expired afterward would otherwise leave the socket live
      # indefinitely. Requires authenticate: true or :optional (there's no
      # credential to reverify without it) and defaults to nil (disabled),
      # same as ping_interval:. Under :optional it watches only the
      # connections that have a session.
      #
      # authenticate: :optional is the middle mode (docs/design/websocket.md,
      # "Anonymous connections"): a connection with a valid session gets its
      # subject, and one without -- no credential, or a revoked or expired
      # one -- comes in anonymous (subject nil) instead of being refused.
      # What an anonymous connection may then do is the handler's call:
      # Monk::Live's rules deny it everything a rule doesn't open with
      # `anonymous: true`. The Origin check still applies: to a cookie, as
      # under true, and to an anonymous connection that sends an Origin,
      # since only a browser does.
      #
      # db_pool: (a pool name, docs/history/plan-pg-pool.md) runs those
      # Monk::Auth.verify calls -- the handshake's and reverify_interval's
      # -- in that Monk::Persistence::Pg pool instead of in the socket's
      # own Ractor. Without it, each socket's Ractor opens a connection of
      # its own on the first verify and holds it while the socket is open:
      # one Postgres connection per open page. With it, the server holds
      # the pool's. Requires authenticate:, and the pool started
      # (start_pools!) before the server.
      #
      # max_payload_size: (bytes) -- see Connection::DEFAULT_MAX_PAYLOAD_SIZE
      # for what it guards against (gap 5). Unlike ping_interval:/
      # reverify_interval:, always on: this is insurance against a
      # hostile client on a public endpoint, not an opt-in behavior
      # change, so a server that doesn't mention it still gets the
      # default cap rather than no cap at all.
      #
      # max_handshakes: caps the connections still in their handshake (the
      # HTTP upgrade and, with authenticate:, verifying the session). At the
      # cap the accept loop stops accepting until one finishes, and new
      # connects wait in the kernel's listen backlog. Without it, a burst
      # past what the process can verify (a restart's reconnect wave) starts
      # every handshake at once, fills db_pool:'s queue, and ends with most
      # of them timing out instead of the rest queueing
      # (docs/plan-ws-connect-ceiling.md, item 1). Kept well under the
      # pool's queue (1,000 by default), so a full cap can't overfill it.
      # Always on, like max_payload_size:.
      #
      # handshake_timeout: (seconds) bounds the whole handshake, from
      # accept to the 101, and Handshake::MAX_REQUEST_SIZE its request; a
      # client past the deadline is dropped, one past the size gets a 431.
      # Without them, a socket that connects and sends nothing holds a
      # max_handshakes: slot forever, so a few hundred of them would shut
      # the server, and a request that never ends grows without limit
      # (item 2). Off once the 101 is written: an idle socket is the
      # handler's business, not the handshake's.
      AUTHENTICATE_MODES = [false, true, :optional].freeze

      DEFAULT_MAX_HANDSHAKES = 128
      DEFAULT_HANDSHAKE_TIMEOUT = 10

      # The signals #run treats as "stop": Ctrl+C and TERM.
      STOP_SIGNALS = [Signal.list.fetch("INT"), Signal.list.fetch("TERM")].freeze

      def initialize(
        port:, bind: "0.0.0.0", allowed_origins: nil, authenticate: false, ping_interval: nil,
        reverify_interval: nil, max_payload_size: Connection::DEFAULT_MAX_PAYLOAD_SIZE, db_pool: nil,
        max_handshakes: DEFAULT_MAX_HANDSHAKES, handshake_timeout: DEFAULT_HANDSHAKE_TIMEOUT
      )
        if ping_interval && !ping_interval.positive?
          raise ArgumentError, "ping_interval must be positive, got #{ping_interval.inspect}"
        end

        unless AUTHENTICATE_MODES.include?(authenticate)
          raise ArgumentError, "authenticate must be false, true or :optional, got #{authenticate.inspect}"
        end

        if reverify_interval
          unless reverify_interval.positive?
            raise ArgumentError, "reverify_interval must be positive, got #{reverify_interval.inspect}"
          end
          raise ArgumentError, "reverify_interval requires authenticate: true or :optional" unless authenticate
        end

        raise ArgumentError, "db_pool requires authenticate: true or :optional" if db_pool && !authenticate

        unless max_payload_size.positive?
          raise ArgumentError, "max_payload_size must be positive, got #{max_payload_size.inspect}"
        end

        unless max_handshakes.is_a?(Integer) && max_handshakes.positive?
          raise ArgumentError, "max_handshakes must be a positive Integer, got #{max_handshakes.inspect}"
        end

        unless handshake_timeout.is_a?(Numeric) && handshake_timeout.positive?
          raise ArgumentError, "handshake_timeout must be positive, got #{handshake_timeout.inspect}"
        end

        if authenticate
          unless defined?(Monk::Auth) && Monk::Auth.config
            raise Monk::AuthNotConfiguredError,
              "Monk::WebSocket::Server.new(authenticate: #{authenticate.inspect}) requires Monk::Auth to " \
              "already be configured -- call Monk::Auth.configure first"
          end

          # Monk::Auth's config is a plain, unfrozen Hash until this runs
          # (lib/monk/freeze_hooks.rb) -- without it, the first
          # Monk::Auth.verify call from inside a connection Ractor raises
          # Ractor::IsolationError (docs/history/plan-websocket.md Phase 5 step 20).
          # Called here, not left to the boot script to remember, the same
          # way Base.call already auto-freezes on first use rather than
          # trusting every app to call Base.freeze! itself.
          Monk.freeze!
        end

        # Raises now, not on the first connection, if the pool was never
        # declared or isn't started in this process.
        Monk::Persistence::Pg.pool(db_pool) if db_pool

        @tcp_server = TCPServer.new(bind, port)
        @allowed_origins = allowed_origins ? Ractor.make_shareable(allowed_origins.dup) : nil
        @authenticate = authenticate
        @ping_interval = ping_interval
        @reverify_interval = reverify_interval
        @max_payload_size = max_payload_size
        @db_pool = db_pool
        @max_handshakes = max_handshakes
        @handshake_timeout = handshake_timeout
      end

      def port
        @tcp_server.addr[1]
      end

      def run(&block)
        shareable_block =
          begin
            Ractor.make_shareable(block)
          rescue ArgumentError, Ractor::IsolationError => e
            raise Monk::UnshareableBlockError,
              "Monk::WebSocket::Server#run block is not Ractor-shareable: #{e.message} " \
              "(build it where self is shareable, e.g. at class-body scope, not inline in a script's " \
              "top-level block -- mirrors StateRactor#update's own constraint)"
          end

        # One slot a handshake in flight (max_handshakes:). Each connection
        # Ractor sends to handshake_done once its handshake is over, however
        # it ended, and the releaser thread frees a slot for it.
        slots = Thread::SizedQueue.new(@max_handshakes)
        handshake_done = Ractor::Port.new
        releaser = Thread.new do
          loop do
            handshake_done.receive
            slots.pop
          end
        end

        loop do
          slots.push(true)
          socket = @tcp_server.accept
          ractor = Ractor.new(
            shareable_block, @authenticate, @allowed_origins, @ping_interval, @reverify_interval, @max_payload_size,
            @db_pool, handshake_done, @handshake_timeout
          ) do |blk, authenticate, origins, ping_interval, reverify_interval, max_payload_size, db_pool, done, timeout|
            Monk::WebSocket::Server.serve(
              Ractor.receive, blk,
              authenticate: authenticate, allowed_origins: origins, ping_interval: ping_interval,
              reverify_interval: reverify_interval, max_payload_size: max_payload_size, db_pool: db_pool,
              handshake_done: done, handshake_timeout: timeout
            )
          end
          ractor.send(socket, move: true)
        end
      rescue SignalException => e
        raise unless STOP_SIGNALS.include?(e.signo)

        # Ctrl+C (INT, raised as Interrupt) and TERM (what docker stop,
        # Kubernetes, Fly, Render and systemd send on every deploy) both
        # land here: Ruby raises them in the thread blocked in
        # TCPServer#accept. Unrescued, INT prints a backtrace and TERM ends
        # the process by the signal (exit 143) -- either reads as a crash
        # though it's the normal way to stop a long-running server. Here
        # the server stops accepting and #run returns, so the script ends
        # with exit 0, as bin/server and bin/jobs do. Open connections are
        # dropped when the process exits, with no close frame
        # (docs/design/websocket.md, "Stopping the server").
        # Registry#ask's Ractor::ClosedError rescue (registry.rb) guards a
        # different failure point in this same shutdown -- a live
        # connection's cleanup racing the registry Ractor's teardown.
        @tcp_server.close
      ensure
        releaser&.kill
        handshake_done&.close
      end

      # Runs entirely inside the connection's own dedicated Ractor
      # (docs/history/plan-websocket.md Decision 3) -- a class method, not an instance
      # method, since the Server instance itself (holding a live
      # TCPServer) is never Ractor-shareable and can't cross into here.
      #
      # handshake_done: is #run's port for max_handshakes:, told once the
      # handshake is over: the 101 written, or the connection refused or
      # dropped before it.
      def self.serve(
        socket, block, authenticate: false, allowed_origins: nil, ping_interval: nil, reverify_interval: nil,
        max_payload_size: Connection::DEFAULT_MAX_PAYLOAD_SIZE, db_pool: nil, handshake_done: nil,
        handshake_timeout: DEFAULT_HANDSHAKE_TIMEOUT
      )
        # A `return` in here (a refused handshake) ends serve, and its
        # ensure frees the slot.
        headers, subject = with_deadline(socket, handshake_timeout) do
          request = read_handshake_request(socket)
          return unless request
          return socket.write("HTTP/1.1 431 Request Header Fields Too Large\r\n\r\n") if request == :too_large

          headers =
            begin
              Handshake.parse_request(request)
            rescue Monk::WebSocket::HandshakeError
              return socket.write("HTTP/1.1 400 Bad Request\r\n\r\n")
            end

          subject = nil
          case authenticate
          when true
            subject = authenticate!(socket, headers, allowed_origins, db_pool)
            return unless subject
          when :optional
            return unless origin_allowed_for_optional?(socket, headers, allowed_origins)

            subject = identify(headers, db_pool)
          end

          socket.write(Handshake.response_for(request))
          [headers, subject]
        end
        handshake_done = handshake_over(handshake_done)

        connection = Connection.new(socket, subject: subject, max_payload_size: max_payload_size)
        connection.start_heartbeat(ping_interval) if ping_interval
        reverify_thread =
          if reverify_interval && subject
            start_reverify(connection, Handshake.credential_from(headers)[:token], reverify_interval, db_pool)
          end
        begin
          block.call(connection)
        rescue StandardError
          # Isolates this connection's failure to its own Ractor
          # (docs/history/plan-websocket.md step 12): neither the accept loop nor any
          # other connection's Ractor is affected. Deliberately swallowed,
          # not re-raised -- there's no caller left to hand it to once
          # we're inside this connection's own dedicated Ractor.
        end
      rescue IOError, SystemCallError
        # The client went away, or was shut out by the deadline, before
        # the handshake was over: nothing to answer.
      ensure
        # Runs on every exit path -- normal completion, the close
        # handshake, and a crashed handler alike -- so a subscribed
        # connection never leaks a stale registry entry (step 17), a
        # heartbeat thread, or a reverify thread outliving its socket.
        # A handshake that never reached its 101 still frees its slot.
        handshake_over(handshake_done)
        reverify_thread&.kill
        connection&.unsubscribe!
        connection&.stop_heartbeat!
        socket.close
        disconnect_all
      end

      # Runs the block with a watchdog that shuts the socket down once
      # `seconds` have passed, which ends a read or write blocked on it (a
      # read returns nil, a write raises). Not IO#timeout=: on Ruby 4.0,
      # once an IO#timeout has fired in one Ractor, reads in Ractors made
      # after it can raise IO::TimeoutError on sockets with no timeout set.
      def self.with_deadline(socket, seconds)
        watchdog = Thread.new do
          sleep seconds
          socket.shutdown(:RDWR)
        rescue IOError, SystemCallError
          # Already closed or gone.
        end
        yield
      ensure
        watchdog&.kill
      end
      private_class_method :with_deadline

      # Frees this connection's max_handshakes: slot in #run; returns nil,
      # so serve can mark it freed. The port is gone once #run has
      # returned, and then there's no slot to free.
      def self.handshake_over(handshake_done)
        handshake_done&.send(true)
        nil
      rescue Ractor::ClosedError
        nil
      end
      private_class_method :handshake_over

      # Closes the connections this socket's Ractor opened: its database
      # connection (verifying the session without db_pool:, or a block
      # that queries) and a fan-out's publisher (a block that broadcasts).
      # Left alone, each would stay open until the garbage collector
      # happened to run, which a mostly idle server may not do for a long
      # time. The fan-outs are opt-in, so each is closed only if loaded.
      def self.disconnect_all
        Monk::Persistence.disconnect_all
        PgFanout.disconnect_publisher if defined?(PgFanout)
        RedisFanout.disconnect_publisher if defined?(RedisFanout)
      end
      private_class_method :disconnect_all

      # docs/history/plan-websocket.md steps 22-23: the Origin allowlist check runs
      # before Monk::Auth.verify, and only for a cookie-derived
      # credential -- a Bearer connection has no Origin header to check
      # by construction (mirrors require_csrf!'s own Bearer exemption in
      # docs/history/plan-auth.md). Returns the verified subject, or nil after writing
      # the appropriate 403/401 response itself.
      def self.authenticate!(socket, headers, allowed_origins, db_pool)
        credential = Handshake.credential_from(headers)

        if credential&.fetch(:via) == :cookie && allowed_origins
          origin = headers["origin"]
          unless origin && allowed_origins.include?(origin)
            socket.write("HTTP/1.1 403 Forbidden\r\n\r\n")
            return nil
          end
        end

        subject = credential && verify(credential[:token], db_pool)
        socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n") unless subject
        subject
      end
      private_class_method :authenticate!

      # authenticate: :optional's Origin check, before anything is verified.
      # A Bearer connection is exempt, as under true. A cookie needs an
      # allowed Origin, as under true. An anonymous connection that sends an
      # Origin needs an allowed one too: only a browser sends it, and this
      # stops another site's page from opening sockets here on its
      # visitors' behalf; one that sends none (not a browser) gets in.
      # Writes the 403 itself and returns false when refused.
      def self.origin_allowed_for_optional?(socket, headers, allowed_origins)
        return true unless allowed_origins

        credential = Handshake.credential_from(headers)
        return true if credential&.fetch(:via) == :bearer

        origin = headers["origin"]
        # A cookie needs an allowed Origin; without one, only a non-browser
        # client (no Origin at all) is let in.
        allowed = origin.nil? ? !credential : allowed_origins.include?(origin)
        socket.write("HTTP/1.1 403 Forbidden\r\n\r\n") unless allowed
        allowed
      end
      private_class_method :origin_allowed_for_optional?

      # The subject of a valid session, or nil -- no credential, or one
      # Monk::Auth no longer accepts, both mean anonymous under :optional.
      def self.identify(headers, db_pool)
        credential = Handshake.credential_from(headers)
        credential && verify(credential[:token], db_pool)
      end
      private_class_method :identify

      # Sleeps in `interval`-sized steps, re-running Monk::Auth.verify
      # against the same raw credential each time, until it comes back
      # nil (revoked or expired) -- then closes the connection with the
      # standard "policy violation" close code, the one bit of RFC 6455's
      # registered code space that fits "this session is no longer
      # authorized" without inventing an app-specific one. Runs in its
      # own Thread rather than blocking the handler's own read loop,
      # mirroring Connection#start_heartbeat's shape; killed from #serve's
      # ensure the same way.
      def self.start_reverify(connection, raw_token, interval, db_pool)
        Thread.new do
          loop do
            sleep interval
            break unless verify(raw_token, db_pool)
          end
          connection.close(code: 1008, reason: "session no longer valid")
        rescue IOError, Errno::EPIPE, Errno::ECONNRESET
          # The connection already closed via some other path (normal
          # disconnect, the close handshake, a dead ping) -- nothing left
          # to close.
        end
      end
      private_class_method :start_reverify

      # Monk::Auth.verify, here or in the db_pool: pool (Server.new).
      def self.verify(raw_token, db_pool)
        return Monk::Auth.verify(raw_token) unless db_pool

        Monk::Persistence::Pg.pool(db_pool).call(Monk::Auth, :verify, raw_token)
      end
      private_class_method :verify

      # The request head, nil if the client went away or was too slow, or
      # :too_large past Handshake::MAX_REQUEST_SIZE.
      def self.read_handshake_request(socket)
        request = +""
        until request.end_with?("\r\n\r\n")
          return :too_large if request.bytesize >= Handshake::MAX_REQUEST_SIZE

          chunk = socket.read(1)
          return nil if chunk.nil?

          request << chunk
        end
        request
      end
      private_class_method :read_handshake_request
    end
  end
end
