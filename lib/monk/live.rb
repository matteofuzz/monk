require_relative "../monk"
require_relative "live/errors"
require_relative "live/renderer"

# Opt-in, like Monk::WebSocket and Monk::Auth: require "monk/live"
# explicitly. `require "monk"` alone must not load this (ADR 0008).
module Monk
  module Live
  end
end
