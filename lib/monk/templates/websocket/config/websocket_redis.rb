require "monk"
require "monk/websocket"
require "monk/websocket/redis_fanout"
require_relative "redis"

# The WebSocket registry (monk add websocket): which sockets are subscribed
# to which topics, and how a broadcast reaches them. bin/server, bin/jobs
# and bin/websocket_server are separate processes, so Redis carries a
# broadcast from one to the others, at REDIS_URL (config/redis.rb). To
# switch to Postgres: SETUP.md, websocket.
module AppWebSocket
  TRANSPORT = "redis".freeze

  # A registry over this app's transport. bin/websocket_server's (REGISTRY)
  # also listens; every other process only publishes.
  def self.build_registry
    Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: Monk::Settings[:redis_url])
  end

  REGISTRY = build_registry
end
