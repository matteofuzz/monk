require_relative "test_helper"
require "json"
require "timeout"

# Monk::Live publishes through the app's WebSocket registry
# (config/websocket.rb): an update reaches a socket subscribed to its topic.
# SETUP.md, live.
class LiveTest < Minitest::Test
  def test_an_update_reaches_a_subscribed_socket
    assert_same AppWebSocket::REGISTRY, Monk::Live.registry
    AppWebSocket::REGISTRY.listen!
    port = Ractor::Port.new
    AppWebSocket::REGISTRY.register(:"live:check", port)

    Monk::Live.remove("live:check", to: "#gone")

    assert_equal "remove", JSON.parse(Timeout.timeout(5) { port.receive })["mode"]
  ensure
    AppWebSocket::REGISTRY.unregister(:"live:check", port) if port
    port&.close
  end
end
