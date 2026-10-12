# Socket handlers for bin/websocket_server, in an app without Monk::Live
# (with live, the server runs live's handler instead).
#
# monk:example websocket-chat -- one chat room: what a socket sends goes to every socket.
# # The handler runs in each connection's own Ractor, so it's built in a
# # module body, where self is shareable.
# module AppSockets
#   HANDLER = proc do |connection|
#     connection.subscribe(AppWebSocket::REGISTRY, :chat)
#     loop do
#       message = connection.read
#       break unless message
#
#       AppWebSocket::REGISTRY.broadcast(:chat, "#{connection.subject || "guest"}: #{message}")
#     end
#   end
# end
# monk:end
