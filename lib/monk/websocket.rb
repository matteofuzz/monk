require_relative "errors"
# Standalone, dependency-free -- required here so Server.new(authenticate:
# true) always raises this precise error, per ADR 0003, rather than a bare
# NameError when an app calls it without ever requiring "monk/auth" at all.
require_relative "auth/errors"
require_relative "websocket/errors"
require_relative "websocket/handshake"
require_relative "websocket/frame"
require_relative "websocket/connection"
require_relative "websocket/server"
require_relative "websocket/registry"

# Opt-in, like Monk::Persistence backends and Monk::Auth: require
# "monk/websocket" explicitly. `require "monk"` alone must not load this
# (PLAN-WEBSOCKET.md Decision 7).
module Monk
  module WebSocket
  end
end
