# Monk::Live wiring, required by both processes: config/load.rb (this app
# publishes updates, e.g. from a route) and bin/websocket_server (the browsers'
# sockets terminate there and are handed the updates).
#
# They are separate processes, so *something* has to carry a publish from
# one to the other. `monk new --live --postgres` (and not --redis) wired
# this file instead of the Redis-based default -- Postgres LISTEN/NOTIFY
# carries the publish instead, reusing the exact DB_* env vars
# config/persistence.rb already reads, so there's no Redis to run. The
# tradeoff: a single broadcast is capped at just under 8000 bytes
# (Monk::WebSocket::PgFanout::MAX_NOTIFY_PAYLOAD_BYTES, Postgres's own
# NOTIFY limit) -- regenerate with --redis instead if that becomes a real
# constraint. Full design in the monk gem's own docs/design/live-pg-fanout.md.
require_relative "settings"
require "monk/live"
require "monk/websocket/pg_fanout"

# Where the browser opens its WebSocket (read by the layout). In
# development there's no reverse proxy in front, so this is the direct WS
# port; outside development it defaults to a /ws path under public_url
# (config/settings.rb) -- matching the path-based proxy routing
# docs/guides/deploying.md's "Adding Monk::WebSocket" section sets up, so
# setting PUBLIC_URL alone keeps this in sync instead of two env vars
# drifting apart. Override with LIVE_WS_URL directly if your setup doesn't
# fit that shape.
default_live_ws_url =
  if Monk.env.development?
    "ws://localhost:9293"
  else
    Monk::Settings[:public_url].sub(/\Ahttps:\/\//, "wss://").sub(/\Ahttp:\/\//, "ws://") + "/ws"
  end

Monk::Settings.configure do
  optional :live_ws_url, default: default_live_ws_url
end

Monk::Live.configure(
  registry: Monk::WebSocket::PgFanout.new(
    Monk::WebSocket::Registry.new,
    pg_opts: {
      host: ENV.fetch("DB_HOST", "127.0.0.1"),
      port: ENV.fetch("DB_PORT", "5432").to_i,
      user: ENV.fetch("DB_USER", "postgres"),
      password: ENV.fetch("DB_PASSWORD", "postgres"),
      dbname: ENV.fetch("DB_NAME", "app_development"),
    },
  ),
)

# Who may subscribe to what. Nothing is allowed unless a rule says so, and an
# anonymous connection is denied unless the rule opts in with `anonymous: true`.
# Rule blocks must be Ractor-shareable, so they live in a module (self at the
# top of this file is not).
#
# monk:example live-rule -- uncomment and adapt: each person may subscribe to
# their own contacts topic (subject is the logged-in user, nil for a visitor).
# module AppLive
#   OWN_CONTACTS = proc { |subject, topic| topic == "contacts:#{subject}" }
# end
# Monk::Live.authorize("contacts:*", &AppLive::OWN_CONTACTS)
# monk:end

# monk:demo live -- the demo's topic (app/routes/demo_live.rb), development
# only. Remove these lines with it.
if Monk.env.development?
  Monk::Live.authorize("demo:hits", anonymous: true, &Monk::Live::ALLOW_ALL)
end
# monk:end
