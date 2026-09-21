# Monk::Live wiring, required by both processes: config.ru (this app
# publishes updates, e.g. from a route) and bin/websocket_server (the browsers'
# sockets terminate there and are handed the updates).
#
# They are separate processes, so Redis is what carries a publish from one to
# the other -- REDIS_URL (set in .env by `monk new --live`) is required.
require_relative "settings"
require "monk/live"
require "monk/websocket/redis_fanout"

Monk::Settings.configure do
  # Where the browser opens its WebSocket (read by the layout). Use wss:// in
  # production.
  optional :live_ws_url, default: "ws://localhost:9293"
end

redis_url = ENV["REDIS_URL"] or raise "Monk::Live needs REDIS_URL: bin/server and bin/websocket_server " \
  "are separate processes, and Redis is how an update published in one reaches a socket in the other"

Monk::Live.configure(
  registry: Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: redis_url),
)

# Who may subscribe to what. Nothing is allowed unless a rule says so, and an
# anonymous connection is denied unless the rule opts in with `anonymous: true`.
# The rule blocks live in a module because they have to be Ractor-shareable
# (self at the top of this file is not).
module AppLive
  # The demo counter is public. A real rule looks at who is asking:
  #   proc { |subject, topic| topic == "contacts:#{subject}" }
  PUBLIC = proc { |_subject, _topic| true }
end

Monk::Live.authorize("hits", anonymous: true, &AppLive::PUBLIC)
