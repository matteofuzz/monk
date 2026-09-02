require_relative "test_helper"
require "monk/auth"

class AuthRateLimitTest < Minitest::Test
  def test_exceeded_is_false_for_the_first_limit_calls_then_true_within_the_same_window
    limiter = Monk::Auth::RateLimiter.new(limit: 3, window: 60)

    results = Array.new(4) { limiter.exceeded?("a@b.com") }

    assert_equal [false, false, false, true], results
  end

  def test_exceeded_tracks_independent_counters_per_key
    limiter = Monk::Auth::RateLimiter.new(limit: 1, window: 60)

    refute limiter.exceeded?("a@b.com")
    refute limiter.exceeded?("c@d.com")
    assert limiter.exceeded?("a@b.com")
  end

  # The actual regression this phase exists for: a StateRactor#update block
  # must be built where self is shareable, not inline in a route handler
  # (CONTEXT.md's StateRactor rule) -- a route using the rate limiter must
  # still pass Base#freeze!, which is exactly what UnshareableBlockError
  # exists to catch if that rule is violated.
  def test_a_route_using_the_rate_limiter_rejects_the_n_plus_first_request_with_429_and_the_app_still_freezes
    app = Class.new(Monk::Base) do
      limiter = Monk::Auth::RateLimiter.new(limit: 2, window: 60)

      post("/auth/request/:email") do |ctx|
        ctx.halt(429) if limiter.exceeded?(ctx.params[:email])
        ctx.json(ok: true)
      end
    end

    app.freeze!

    statuses = Array.new(3) { app.call(env_for("POST", "/auth/request/a@b.com")).first }

    assert_equal [200, 200, 429], statuses
  end
end
