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

  def test_a_body_of_another_content_type_is_not_parsed
    app = Class.new(Monk::Base) do
      post("/x") { params[:email].inspect }
    end

    status, _headers, body = app.call(post_env("text/plain", "email=a@b.com"))

    assert_equal 200, status
    assert_equal "nil", body.join
  end

  def test_a_form_body_is_parsed_into_params
    app = Class.new(Monk::Base) do
      post("/x") { "#{params[:email]} #{params[:user][:name]} #{params[:tags].join(",")}" }
    end

    _status, _headers, body = app.call(post_env("application/x-www-form-urlencoded; charset=UTF-8",
      "email=a%40b.com&user[name]=Ann&tags[]=a&tags[]=b"))

    assert_equal "a@b.com Ann a,b", body.join
  end

  def test_form_body_params_win_over_query_string_params_and_path_params_win_over_both
    app = Class.new(Monk::Base) do
      post("/x/:id") { "#{params[:id]} #{params[:name]} #{params[:page]}" }
    end

    env = post_env("application/x-www-form-urlencoded", "id=from-body&name=from-body")
    env["PATH_INFO"] = "/x/from-path"
    env["QUERY_STRING"] = "name=from-query&page=2"

    _status, _headers, body = app.call(env)

    assert_equal "from-path from-body 2", body.join
  end

  def test_a_malformed_form_body_is_a_400
    app = Class.new(Monk::Base) do
      post("/x") { "unreachable" }
    end

    status, = app.call(post_env("application/x-www-form-urlencoded", "a=1&a[b]=2"))

    assert_equal 400, status
  end

  def test_a_parsed_body_over_the_cap_is_a_413
    app = Class.new(Monk::Base) do
      post("/x") { "ok" }
    end
    big = "a=#{"x" * Monk::Base::MAX_PARSED_BODY}"

    form_status, = app.call(post_env("application/x-www-form-urlencoded", big))
    json_status, = app.call(post_env("application/json", %({"a":"#{"x" * Monk::Base::MAX_PARSED_BODY}"})))
    plain_status, = app.call(post_env("text/plain", big))

    assert_equal 413, form_status
    assert_equal 413, json_status
    assert_equal 200, plain_status
  end

  def test_a_multipart_body_is_a_415
    app = Class.new(Monk::Base) do
      post("/x") { "unreachable" }
    end

    status, = app.call(post_env("multipart/form-data; boundary=x", "--x--"))

    assert_equal 415, status
  end

  def test_malformed_json_is_a_400
    app = Class.new(Monk::Base) do
      post("/x") { "unreachable" }
    end

    status, = app.call(post_env("application/json", "{not json"))

    assert_equal 400, status
  end

  def test_a_json_body_that_is_not_an_object_is_a_400
    app = Class.new(Monk::Base) do
      post("/x") { "unreachable" }
    end

    status, = app.call(post_env("application/json", "[1, 2]"))

    assert_equal 400, status
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

  def test_nested_query_string_params
    app = Class.new(Monk::Base) do
      get("/x") { "#{params[:user][:name]} #{params[:tags].join(",")}" }
    end

    env = env_for("GET", "/x")
    env["QUERY_STRING"] = "user[name]=Ann&tags[]=a&tags[]=b"

    _status, _headers, body = app.call(env)

    assert_equal "Ann a,b", body.join
  end

  def test_a_malformed_query_string_is_a_400
    app = Class.new(Monk::Base) do
      get("/x") { "unreachable" }
    end

    env = env_for("GET", "/x")
    env["QUERY_STRING"] = "a=1&a[b]=2"

    status, _headers, body = app.call(env)

    assert_equal 400, status
    assert_equal "", body.join
  end

  private

  def post_env(content_type, body)
    env = env_for("POST", "/x")
    env["CONTENT_TYPE"] = content_type
    env["rack.input"] = StringIO.new(body)
    env
  end
end
