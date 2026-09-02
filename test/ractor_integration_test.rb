require_relative "test_helper"

class RactorIntegrationTest < Minitest::Test
  def test_concurrent_ractors_calling_app_get_correct_independent_responses
    app = Class.new(Monk::Base) do
      get("/echo/:id") { params[:id] }
    end
    Monk.boot(app)

    ractors = (1..10).map do |i|
      Ractor.new(app, i) do |a, id|
        env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/echo/#{id}" }
        status, _headers, body = a.call(env)
        [status, body.join]
      end
    end

    results = ractors.map(&:value)

    results.each_with_index do |(status, body), index|
      assert_equal 200, status
      assert_equal (index + 1).to_s, body
    end
  end

  def test_route_reading_ctx_env_still_freezes_and_stays_correct_under_concurrent_ractors
    app = Class.new(Monk::Base) do
      get("/echo/:id") { |ctx| "#{ctx.params[:id]}:#{ctx.env["PATH_INFO"]}" }
    end
    Monk.boot(app)

    assert Ractor.shareable?(app.routes)

    ractors = (1..10).map do |i|
      Ractor.new(app, i) do |a, id|
        env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/echo/#{id}" }
        status, _headers, body = a.call(env)
        [status, body.join]
      end
    end

    results = ractors.map(&:value)

    results.each_with_index do |(status, body), index|
      id = index + 1
      assert_equal 200, status
      assert_equal "#{id}:/echo/#{id}", body
    end
  end

  # Settles, by measurement on this project's actual target (Ruby 4.0.6,
  # .ruby-version), a question PLAN-AUTH.md Phase 5 step 20 left open: does
  # a non-main Ractor read ENV at all, and does it see the same value the
  # main Ractor set? This determines whether lib/monk/base.rb:79's
  # ENV["MONK_ENV"] read (done per-request, inside whichever worker Ractor
  # is serving it) is trustworthy under a real kino pool. A 3.3.6 probe
  # exists in docs/auth-sessions.md but is explicitly not a substitute --
  # see this project's own history of Ractor behavior not porting across
  # versions by assumption (the Phase 0 Sequel spike, the Phase 4/5
  # freezing findings).
  def test_env_is_readable_and_consistent_from_a_real_worker_ractor
    ENV["MONK_RACTOR_ENV_PROBE"] = "main-ractor-value"

    result = Ractor.new { ENV["MONK_RACTOR_ENV_PROBE"] }.value

    assert_equal "main-ractor-value", result
  ensure
    ENV.delete("MONK_RACTOR_ENV_PROBE")
  end

  def test_concurrent_ractors_hammering_a_shared_stateractor_never_lose_an_update
    increments_per_ractor = 25
    ractor_count = 8

    result = Class.new.class_exec do
      counter = Monk::StateRactor.new(0)
      increment = Ractor.make_shareable(proc { |v| v + 1 })

      ractors = Array.new(ractor_count) do
        Ractor.new(counter, increment, increments_per_ractor) do |c, incr, times|
          times.times { c.update(&incr) }
        end
      end
      ractors.each(&:value)

      counter.value
    end

    assert_equal ractor_count * increments_per_ractor, result
  end
end
