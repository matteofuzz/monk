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
