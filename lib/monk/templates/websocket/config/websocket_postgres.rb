require "monk"
require "monk/websocket"
require "monk/websocket/pg_fanout"
require_relative "persistence"

# The WebSocket registry (monk add websocket): which sockets are subscribed
# to which topics, and how a broadcast reaches them. bin/server, bin/jobs
# and bin/websocket_server are separate processes, so Postgres
# LISTEN/NOTIFY carries a broadcast from one to the others, over the
# :primary connection's settings (config/persistence.rb). A broadcast is
# capped at just under 8000 bytes, Postgres's NOTIFY limit. To switch to
# Redis: SETUP.md, websocket.
module AppWebSocket
  TRANSPORT = "postgres".freeze

  # A registry over this app's transport. bin/websocket_server's (REGISTRY)
  # also listens; every other process only publishes.
  def self.build_registry
    Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new,
      pg_opts: Monk::Persistence::Pg.connection_options(:primary),)
  end

  REGISTRY = build_registry
end
