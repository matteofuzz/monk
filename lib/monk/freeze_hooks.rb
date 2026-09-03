module Monk
  # Objects responding to #freeze_registry! that Base#freeze! (Seam B) must
  # seal at boot, so a worker Ractor can read their config without tripping
  # Ractor::IsolationError. Not persistence-specific: Monk::Persistence::
  # Registry backends and Monk::Auth both register themselves here.
  def self.freeze_hooks
    @freeze_hooks ||= []
  end
end
