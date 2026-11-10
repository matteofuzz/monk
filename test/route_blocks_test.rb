require_relative "test_helper"

# freeze! turns route and error-handler blocks into Context methods,
# called per request instead of instance_exec'd: the block still runs
# with self bound to the Context, and still gets the context when it
# asks for it.
class RouteBlocksTest < Minitest::Test
  def test_block_without_parameters_runs_with_self_as_the_context
    app = Class.new(Monk::Base) do
      get("/x") do
        @seen = self.class.name
        @seen
      end
    end

    _status, _headers, body = app.call(env_for("GET", "/x"))

    assert_equal "Monk::Context", body.join
  end

  def test_block_with_one_parameter_gets_the_context
    app = Class.new(Monk::Base) do
      get("/x") { |ctx| ctx.equal?(self).to_s }
    end

    _status, _headers, body = app.call(env_for("GET", "/x"))

    assert_equal "true", body.join
  end

  def test_block_with_optional_and_rest_parameters_gets_the_context
    app = Class.new(Monk::Base) do
      get("/a") { |*args| args.size.to_s }
      get("/b") { |ctx = nil| ctx.class.name }
    end

    assert_equal "1", app.call(env_for("GET", "/a"))[2].join
    assert_equal "Monk::Context", app.call(env_for("GET", "/b"))[2].join
  end

  # instance_exec passes nil for the parameters past the first; a method
  # couldn't, so such a block keeps instance_exec.
  def test_block_with_two_required_parameters_still_gets_nil_for_the_second
    app = Class.new(Monk::Base) do
      get("/x") { |ctx, extra| "#{ctx.class.name} #{extra.inspect}" }
    end

    _status, _headers, body = app.call(env_for("GET", "/x"))

    assert_equal "Monk::Context nil", body.join
  end

  def test_two_apps_with_routes_on_the_same_path_keep_their_own_blocks
    first = Class.new(Monk::Base) { get("/x") { "first" } }
    second = Class.new(Monk::Base) { get("/x") { "second" } }

    assert_equal "first", first.call(env_for("GET", "/x"))[2].join
    assert_equal "second", second.call(env_for("GET", "/x"))[2].join
  end

  def test_halt_and_error_handlers_run_as_methods_too
    app = Class.new(Monk::Base) do
      get("/halt") { halt 418, "teapot" }
      get("/boom") { raise ArgumentError, "boom" }
      error(ArgumentError) { |ctx| "handled #{ctx.status}" }
      error(404) { halt 404, "nothing here" }
    end

    assert_equal [418, ["teapot"]], app.call(env_for("GET", "/halt")).values_at(0, 2)
    assert_equal [500, ["handled 500"]], app.call(env_for("GET", "/boom")).values_at(0, 2)
    assert_equal [404, ["nothing here"]], app.call(env_for("GET", "/nope")).values_at(0, 2)
  end

  def test_route_methods_run_in_a_worker_ractor
    app = Class.new(Monk::Base) do
      get("/x/:id") { |ctx| "id #{ctx.params[:id]}" }
    end
    app.freeze!

    body = Ractor.new(app) do |a|
      a.call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/x/7", "rack.input" => StringIO.new("") })[2].join
    end.value

    assert_equal "id 7", body
  end
end
