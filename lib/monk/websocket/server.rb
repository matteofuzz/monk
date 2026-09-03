require "socket"

module Monk
  module WebSocket
    # Intended to be the entire body of a small standalone script (e.g.
    # bin/websocket_server) -- never embedded in the same process as Kino
    # (PLAN-WEBSOCKET.md Decision 1).
    class Server
      def initialize(port:, bind: "0.0.0.0")
        @tcp_server = TCPServer.new(bind, port)
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
          ractor = Ractor.new(shareable_block) { |blk| Monk::WebSocket::Server.serve(Ractor.receive, blk) }
          ractor.send(socket, move: true)
        end
      end

      # Runs entirely inside the connection's own dedicated Ractor
      # (PLAN-WEBSOCKET.md Decision 3) -- a class method, not an instance
      # method, since the Server instance itself (holding a live
      # TCPServer) is never Ractor-shareable and can't cross into here.
      def self.serve(socket, block)
        request = read_handshake_request(socket)
        return socket.close unless request

        response =
          begin
            Handshake.response_for(request)
          rescue Monk::WebSocket::HandshakeError
            return socket.write("HTTP/1.1 400 Bad Request\r\n\r\n")
          end
        socket.write(response)

        begin
          block.call(Connection.new(socket))
        rescue StandardError
          # Isolates this connection's failure to its own Ractor
          # (PLAN-WEBSOCKET.md step 12): neither the accept loop nor any
          # other connection's Ractor is affected. Deliberately swallowed,
          # not re-raised -- there's no caller left to hand it to once
          # we're inside this connection's own dedicated Ractor.
        end
      ensure
        socket.close
      end

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
