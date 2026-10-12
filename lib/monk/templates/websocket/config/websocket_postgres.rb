require "monk"
require "monk/websocket"
require "monk/websocket/pg_fanout"
require_relative "persistence"

# The WebSocket registry (monk add websocket): which sockets are subscribed
# to which topics, and how a broadcast reaches them. bin/server, bin/jobs
# and bin/websocket_server are separate processes, so Postgres
# LISTEN/NOTIFY carries a broadcast from one to the others, on the
# :primary database (config/persistence.rb). A broadcast is capped at just
# under 8000 bytes, Postgres's NOTIFY limit. To switch to Redis: SETUP.md,
# websocket.
#
# Broadcasts are published through the :notify pool: one connection per
# process, however many Ractors publish. Size 1, so a page's updates are
# sent in the order they were made. Declaring it opens nothing:
# AppWebSocket.start! does, in every process that publishes (config/load.rb
# and bin/websocket_server call it).
Monk::Persistence::Pg.pool(:notify, size: 1)

module AppWebSocket
  TRANSPORT = "postgres".freeze

  # A registry over this app's transport. bin/websocket_server's (REGISTRY)
  # also listens, on a connection of its own; every other process only
  # publishes.
  def self.build_registry
    Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, db_pool: :notify)
  end

  # Opens the :notify pool's connection. At boot, in the main Ractor, once
  # every database and pool is declared.
  def self.start!
    Monk::Persistence::Pg.start_pools!(:notify)
  end

  REGISTRY = build_registry
end
