require_relative "../state_ractor"

module Monk
  module Auth
    # Per-process, approximate rate limiting for POST /auth/request
    # (docs/auth-sessions.md: StateRactor's "real job" here -- durability is
    # explicitly not a goal). Frozen at construction, like StateRactor
    # itself: that's what makes #exceeded? able to build a fresh #update
    # block per call with a shareable self, satisfying CONTEXT.md's
    # StateRactor rule ("build it where self is shareable... not inline in
    # a route handler") without needing StateRactor#update to grow an
    # argument-passing API just to thread a per-call key through.
    class RateLimiter
      def initialize(limit:, window:)
        @limit = limit
        @window = window
        @counts = Monk::StateRactor.new({})
        freeze
      end

      # True if `key` has already made more than `limit` calls within the
      # current `window`-second window; also counts this call toward it.
      def exceeded?(key)
        # Ractor.make_shareable on a Proc requires every variable it
        # captures to already be shareable -- it verifies, it doesn't
        # freeze on the caller's behalf. Integers are always frozen; a
        # caller-supplied String generally isn't, so dup+freeze a local
        # copy (a distinct binding, not a reassignment of `key` -- a
        # captured variable that could be reassigned is itself rejected as
        # unshareable, regardless of what it holds at call time).
        frozen_key = key.dup.freeze
        limit = @limit
        window = @window
        now = Time.now.to_i

        counts = @counts.update do |current|
          count, window_start = current[frozen_key] || [0, now]
          count, window_start = 0, now if now - window_start >= window
          current.merge(frozen_key => [count + 1, window_start])
        end

        counts[frozen_key].first > limit
      end
    end
  end
end
