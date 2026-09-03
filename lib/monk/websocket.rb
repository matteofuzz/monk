require_relative "websocket_handshake_error"
require_relative "websocket_protocol_error"
require_relative "websocket/handshake"
require_relative "websocket/frame"

# Opt-in, like Monk::Persistence backends and Monk::Auth: require
# "monk/websocket" explicitly. `require "monk"` alone must not load this
# (PLAN-WEBSOCKET.md Decision 7).
module Monk
  module WebSocket
  end
end
