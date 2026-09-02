require_relative "test_helper"

class ContextTest < Minitest::Test
  def test_zero_arg_block_resolves_bare_params_via_instance_exec
    app = Class.new(Monk::Base) do
      get("/x/:id") { params[:id] }
    end

    _status, _headers, body = app.call(env_for("GET", "/x/7"))

    assert_equal "7", body.join
  end

  def test_one_arg_block_receives_context_explicitly
    app = Class.new(Monk::Base) do
      get("/x/:id") { |ctx| ctx.params[:id] }
    end

    _status, _headers, body = app.call(env_for("GET", "/x/7"))

    assert_equal "7", body.join
  end

  def test_halt_short_circuits_with_the_given_response
    app = Class.new(Monk::Base) do
      get("/x") do
        halt 400, "bad"
        "unreachable"
      end
    end

    status, _headers, body = app.call(env_for("GET", "/x"))

    assert_equal 400, status
    assert_equal "bad", body.join
  end

  def test_json_helper_serializes_and_sets_content_type
    app = Class.new(Monk::Base) do
      get("/x") { json(hello: "world") }
    end

    _status, headers, body = app.call(env_for("GET", "/x"))

    assert_equal "application/json", headers["content-type"]
    assert_equal '{"hello":"world"}', body.join
  end

  def test_context_env_exposes_the_rack_env_for_the_request
    app = Class.new(Monk::Base) do
      get("/x") { |ctx| ctx.env["HTTP_AUTHORIZATION"] }
    end

    request_env = env_for("GET", "/x")
    request_env["HTTP_AUTHORIZATION"] = "Bearer abc"
    _status, _headers, body = app.call(request_env)

    assert_equal "Bearer abc", body.join
  end

  def test_header_reads_a_request_header_by_its_plain_name
    app = Class.new(Monk::Base) do
      get("/x") { |ctx| ctx.header("authorization") }
    end

    request_env = env_for("GET", "/x")
    request_env["HTTP_AUTHORIZATION"] = "Bearer abc"
    _status, _headers, body = app.call(request_env)

    assert_equal "Bearer abc", body.join
  end

  def test_header_returns_nil_when_the_header_is_absent
    app = Class.new(Monk::Base) do
      get("/x") { |ctx| ctx.header("authorization").inspect }
    end

    _status, _headers, body = app.call(env_for("GET", "/x"))

    assert_equal "nil", body.join
  end
end
