require "socket"

module Monk
  module WebSocket
    # Intended to be the entire body of a small standalone script (e.g.
    # bin/websocket_server) -- never embedded in the same process as Kino
    # (PLAN-WEBSOCKET.md Decision 1).
    class Server
      # allowed_origins: and authenticate: implement PLAN-WEBSOCKET.md
      # Phase 5 (identity via Monk::Auth, reused unmodified -- Decision
      # 5). authenticate: defaults false so a plain server (Phases 1-4)
      # behaves exactly as before; turning it on requires Monk::Auth to
      # already be configured, fail-fast the same way Monk::Auth's own
      # methods do (ADR 0003) rather than failing obscurely on the first
      # connection.
      def initialize(port:, bind: "0.0.0.0", allowed_origins: nil, authenticate: false)
        if authenticate
          unless defined?(Monk::Auth) && Monk::Auth.config
            raise Monk::AuthNotConfiguredError,
              "Monk::WebSocket::Server.new(authenticate: true) requires Monk::Auth to already be " \
              "configured -- call Monk::Auth.configure first"
          end

          # Monk::Auth's config is a plain, unfrozen Hash until this runs
          # (lib/monk/freeze_hooks.rb) -- without it, the first
          # Monk::Auth.verify call from inside a connection Ractor raises
          # Ractor::IsolationError (PLAN-WEBSOCKET.md Phase 5 step 20).
          # Called here, not left to the boot script to remember, the same
          # way Base.call already auto-freezes on first use rather than
          # trusting every app to call Base.freeze! itself.
          Monk.freeze!
        end

        @tcp_server = TCPServer.new(bind, port)
        @allowed_origins = allowed_origins ? Ractor.make_shareable(allowed_origins.dup) : nil
        @authenticate = authenticate
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

        loop do
          socket = @tcp_server.accept
          ractor = Ractor.new(shareable_block, @authenticate, @allowed_origins) do |blk, authenticate, origins|
            Monk::WebSocket::Server.serve(Ractor.receive, blk, authenticate: authenticate, allowed_origins: origins)
          end
          ractor.send(socket, move: true)
        end
      end

      # Runs entirely inside the connection's own dedicated Ractor
      # (PLAN-WEBSOCKET.md Decision 3) -- a class method, not an instance
      # method, since the Server instance itself (holding a live
      # TCPServer) is never Ractor-shareable and can't cross into here.
      def self.serve(socket, block, authenticate: false, allowed_origins: nil)
        request = read_handshake_request(socket)
        return socket.close unless request

        headers =
          begin
            Handshake.parse_request(request)
          rescue Monk::WebSocket::HandshakeError
            return socket.write("HTTP/1.1 400 Bad Request\r\n\r\n")
          end

        subject = nil
        if authenticate
          subject = authenticate!(socket, headers, allowed_origins)
          return unless subject
        end

        socket.write(Handshake.response_for(request))

        connection = Connection.new(socket, subject: subject)
        begin
          block.call(connection)
        rescue StandardError
          # Isolates this connection's failure to its own Ractor
          # (PLAN-WEBSOCKET.md step 12): neither the accept loop nor any
          # other connection's Ractor is affected. Deliberately swallowed,
          # not re-raised -- there's no caller left to hand it to once
          # we're inside this connection's own dedicated Ractor.
        end
      ensure
        # Runs on every exit path -- normal completion, the close
        # handshake, and a crashed handler alike -- so a subscribed
        # connection never leaks a stale registry entry (step 17).
        connection&.unsubscribe!
        socket.close
      end

      # PLAN-WEBSOCKET.md steps 22-23: the Origin allowlist check runs
      # before Monk::Auth.verify, and only for a cookie-derived
      # credential -- a Bearer connection has no Origin header to check
      # by construction (mirrors require_csrf!'s own Bearer exemption in
      # PLAN-AUTH.md). Returns the verified subject, or nil after writing
      # the appropriate 403/401 response itself.
      def self.authenticate!(socket, headers, allowed_origins)
        credential = Handshake.credential_from(headers)

        if credential&.fetch(:via) == :cookie && allowed_origins
          origin = headers["origin"]
          unless origin && allowed_origins.include?(origin)
            socket.write("HTTP/1.1 403 Forbidden\r\n\r\n")
            return nil
          end
        end

        subject = credential && Monk::Auth.verify(credential[:token])
        socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n") unless subject
        subject
      end
      private_class_method :authenticate!

      def self.read_handshake_request(socket)
        request = +""
        until request.end_with?("\r\n\r\n")
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
