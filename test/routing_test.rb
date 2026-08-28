require_relative "test_helper"

class RoutingTest < Minitest::Test
  def test_get_route_returns_registered_body_with_200
    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    status, _headers, body = app.call(env_for("GET", "/x"))

    assert_equal 200, status
    assert_equal "hi", body.join
  end

  def test_unmatched_path_returns_404
    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    status, _headers, _body = app.call(env_for("GET", "/does-not-exist"))

    assert_equal 404, status
  end

  def test_routes_dispatch_by_verb
    app = Class.new(Monk::Base) do
      get("/x") { "got-get" }
      post("/x") { "got-post" }
      put("/x") { "got-put" }
      patch("/x") { "got-patch" }
      delete("/x") { "got-delete" }
    end

    { "GET" => "got-get", "POST" => "got-post", "PUT" => "got-put",
      "PATCH" => "got-patch", "DELETE" => "got-delete" }.each do |verb, expected|
      _status, _headers, body = app.call(env_for(verb, "/x"))
      assert_equal expected, body.join
    end
  end

  def test_verb_mismatch_on_known_path_returns_404
    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    status, _headers, _body = app.call(env_for("POST", "/x"))

    assert_equal 404, status
  end

  def test_path_param_is_captured
    app = Class.new(Monk::Base) do
      get("/users/:id") { params[:id] }
    end

    _status, _headers, body = app.call(env_for("GET", "/users/42"))

    assert_equal "42", body.join
  end

  def test_splat_segment_is_captured
    app = Class.new(Monk::Base) do
      get("/files/*") { params[:splat] }
    end

    _status, _headers, body = app.call(env_for("GET", "/files/a/b/c"))

    assert_equal "a/b/c", body.join
  end
end
