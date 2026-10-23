require_relative "test_helper"
require "timeout"

# A broadcast crosses processes over this app's transport
# (config/websocket.rb): a second registry, built the same way, publishes
# as bin/server would, and AppWebSocket::REGISTRY, listening as
# bin/websocket_server does, delivers it. SETUP.md, websocket.
class WebSocketTest < Minitest::Test
  def test_a_broadcast_reaches_a_socket_through_the_transport
    AppWebSocket::REGISTRY.listen!
    port = Ractor::Port.new
    AppWebSocket::REGISTRY.register(:websocket_check, port)

    AppWebSocket.build_registry.broadcast(:websocket_check, "hello")

    assert_equal "hello", Timeout.timeout(5) { port.receive }
  ensure
    AppWebSocket::REGISTRY.unregister(:websocket_check, port) if port
    port&.close
  end
end
