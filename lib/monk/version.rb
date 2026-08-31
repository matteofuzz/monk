module Monk
  # Frozen, not just a plain literal: reading a String constant from a
  # non-main Ractor raises Ractor::IsolationError unless it's shareable,
  # and a frozen String with no unshareable ivars qualifies -- the same
  # class of bug .freeze! guards against for routes/error handlers/models,
  # just on a top-level constant that every worker Ractor reads on boot
  # (found live under kino: GET /hello 500'd until this was frozen).
  VERSION = "0.4.0".freeze
end
