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

  def test_headers_set_on_context_are_merged_into_a_normal_response
    app = Class.new(Monk::Base) do
      get("/x") do
        headers["X-Custom"] = "value"
        "hi"
      end
    end

    _status, headers, body = app.call(env_for("GET", "/x"))

    assert_equal "value", headers["X-Custom"]
    assert_equal "hi", body.join
  end

  def test_headers_set_on_context_are_merged_into_a_halt_response
    app = Class.new(Monk::Base) do
      get("/x") do
        headers["X-Custom"] = "value"
        halt 400, "bad"
      end
    end

    status, headers, body = app.call(env_for("GET", "/x"))

    assert_equal 400, status
    assert_equal "value", headers["X-Custom"]
    assert_equal "bad", body.join
  end

  def test_headers_set_on_context_are_merged_into_a_json_response
    app = Class.new(Monk::Base) do
      get("/x") do
        headers["X-Custom"] = "value"
        json(hello: "world")
      end
    end

    _status, headers, _body = app.call(env_for("GET", "/x"))

    assert_equal "value", headers["X-Custom"]
    assert_equal "application/json", headers["content-type"]
  end

  def test_redirect_returns_302_by_default_with_a_location_header_and_no_token_in_the_url
    app = Class.new(Monk::Base) do
      get("/x") { redirect "/somewhere" }
    end

    status, headers, = app.call(env_for("GET", "/x"))

    assert_equal 302, status
    assert_equal "/somewhere", headers["location"]
  end

  def test_redirect_accepts_a_custom_status
    app = Class.new(Monk::Base) do
      get("/x") { redirect "/somewhere", status: 301 }
    end

    status, headers, = app.call(env_for("GET", "/x"))

    assert_equal 301, status
    assert_equal "/somewhere", headers["location"]
  end

  def test_header_returns_nil_when_the_header_is_absent
    app = Class.new(Monk::Base) do
      get("/x") { |ctx| ctx.header("authorization").inspect }
    end

    _status, _headers, body = app.call(env_for("GET", "/x"))

    assert_equal "nil", body.join
  end

  def test_settings_reads_a_declared_key_from_inside_a_route
    with_settings do
      with_env("MONK_TEST_API_KEY", "secret") do
        Monk::Settings.configure { required :monk_test_api_key }

        app = Class.new(Monk::Base) do
          get("/x") { settings[:monk_test_api_key] }
        end

        _status, _headers, body = app.call(env_for("GET", "/x"))

        assert_equal "secret", body.join
      end
    end
  end

  def test_settings_raises_the_same_way_as_monk_settings_for_an_undeclared_key
    with_settings do
      app = Class.new(Monk::Base) do
        get("/x") { settings[:monk_test_mystery] }
        error(Monk::UnknownSettingError) { json(error: "unknown setting") }
      end

      _status, _headers, body = app.call(env_for("GET", "/x"))

      assert_equal '{"error":"unknown setting"}', body.join
    end
  end
end
