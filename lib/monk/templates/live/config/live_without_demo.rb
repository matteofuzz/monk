require "monk"
require "monk/live"
require_relative "websocket"

# Monk::Live (monk add live): HTML pushed to open pages, over the app's
# WebSocket registry (config/websocket.rb), so it has no transport of its
# own. Loaded by config/load.rb (bin/server and bin/jobs publish) and by
# bin/websocket_server (it delivers).

# Where the browser opens its WebSocket, for the layout's <%= monk_head %>:
# the direct port in development; elsewhere a /ws path under public_url
# (config/settings.rb), matching the proxy docs/guides/deploying.md sets
# up, so PUBLIC_URL alone keeps both in sync. LIVE_WS_URL overrides it.
default_live_ws_url =
  if Monk.env.development?
    "ws://localhost:9293"
  else
    Monk::Settings[:public_url].sub(%r{\Ahttps://}, "wss://").sub(%r{\Ahttp://}, "ws://") + "/ws"
  end

Monk::Settings.configure do
  optional :live_ws_url, default: default_live_ws_url
end

Monk::Live.configure(registry: AppWebSocket::REGISTRY)

# Who may subscribe to what. Nothing is allowed unless a rule says so, and an
# anonymous socket is denied unless its rule says `anonymous: true`. Rule
# blocks must be Ractor-shareable, so they're built in a module (self at the
# top of this file is not); Monk::Live::ALLOW_ALL lets everyone in.
#
# monk:example live-rule -- each person may subscribe to their own contacts topic.
# # subject is the logged-in user (with auth), nil for a visitor.
# module AppLive
#   OWN_CONTACTS = proc { |subject, topic| topic == "contacts:#{subject}" }
# end
# Monk::Live.authorize("contacts:*", &AppLive::OWN_CONTACTS)
# monk:end
