module Monk
  # Objects responding to #freeze_registry! that Base#freeze! (Seam B) must
  # seal at boot, so a worker Ractor can read their config without tripping
  # Ractor::IsolationError. Not persistence-specific: Monk::Persistence::
  # Registry backends and Monk::Auth both register themselves here.
  def self.freeze_hooks
    @freeze_hooks ||= []
  end

  # Extracted out of Base#freeze! (PLAN-WEBSOCKET.md Phase 5 step 20):
  # Monk::Base.freeze! calls this, but so can any process that never
  # touches Monk::Base at all -- Monk::WebSocket::Server's boot script,
  # per Decision 1 -- and still needs Monk::Auth/Monk::Persistence config
  # readable from a worker Ractor. Without this, that config stays an
  # unfrozen Hash, and the first Monk::Auth.verify call from inside a
  # connection Ractor raises Ractor::IsolationError -- the same bug class
  # already hit and fixed for persistence (Phase 4/5) and for Base-booted
  # auth (PLAN-AUTH.md Phase 5 step 17).
  def self.freeze!
    freeze_hooks.each(&:freeze_registry!)
    Persistence::Model.freeze_all!
  end
end
