require_relative "test_helper"
require "stringio"

class ParamsParsingTest < Minitest::Test
  def test_query_string_is_parsed_into_params
    app = Class.new(Monk::Base) do
      get("/x") { params[:token] }
    end

    env = env_for("GET", "/x")
    env["QUERY_STRING"] = "token=abc123"

    _status, _headers, body = app.call(env)

    assert_equal "abc123", body.join
  end

  def test_json_body_is_parsed_into_params
    app = Class.new(Monk::Base) do
      post("/x") { params[:email] }
    end

    env = env_for("POST", "/x")
    env["CONTENT_TYPE"] = "application/json"
    env["rack.input"] = StringIO.new('{"email":"a@b.com"}')

    _status, _headers, body = app.call(env)

    assert_equal "a@b.com", body.join
  end

  def test_path_segment_params_take_precedence_over_query_string_params
    app = Class.new(Monk::Base) do
      get("/x/:id") { params[:id] }
    end

    env = env_for("GET", "/x/from-path")
    env["QUERY_STRING"] = "id=from-query"

    _status, _headers, body = app.call(env)

    assert_equal "from-path", body.join
  end

  def test_a_non_json_content_type_body_is_not_parsed_as_json
    app = Class.new(Monk::Base) do
      post("/x") { params[:email].inspect }
    end

    env = env_for("POST", "/x")
    env["CONTENT_TYPE"] = "application/x-www-form-urlencoded"
    env["rack.input"] = StringIO.new("email=a@b.com")

    _status, _headers, body = app.call(env)

    assert_equal "nil", body.join
  end

  def test_an_empty_json_content_type_body_does_not_raise
    app = Class.new(Monk::Base) do
      post("/x") { "ok" }
    end

    env = env_for("POST", "/x")
    env["CONTENT_TYPE"] = "application/json"

    status, = app.call(env)

    assert_equal 200, status
  end
end
