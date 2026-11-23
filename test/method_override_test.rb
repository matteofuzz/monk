require_relative "test_helper"

class MethodOverrideTest < Minitest::Test
  def app
    Class.new(Monk::Base) do
      post("/items/:id") { "post #{params[:id]}" }
      patch("/items/:id") { "patch #{params[:id]} #{params[:name]}" }
      put("/items/:id") { "put" }
      delete("/items/:id") { "delete #{env["REQUEST_METHOD"]}" }
      get("/items/:id") { "get" }
    end
  end

  def test_a_form_post_with_method_patch_reaches_the_patch_route
    _status, _headers, body = app.call(request("POST", "application/x-www-form-urlencoded", "_method=patch&name=Ann"))

    assert_equal "patch 1 Ann", body.join
  end

  def test_put_and_delete_too_and_the_env_shows_the_overridden_verb
    assert_equal "put", app.call(request("POST", "application/x-www-form-urlencoded", "_method=PUT"))[2].join
    assert_equal "delete DELETE",
      app.call(request("POST", "application/x-www-form-urlencoded", "_method=delete"))[2].join
  end

  def test_never_to_get_or_an_unknown_verb
    assert_equal "post 1", app.call(request("POST", "application/x-www-form-urlencoded", "_method=get"))[2].join
    assert_equal "post 1", app.call(request("POST", "application/x-www-form-urlencoded", "_method=bogus"))[2].join
  end

  def test_never_from_the_query_string
    env = request("POST", "application/x-www-form-urlencoded", "name=Ann")
    env["QUERY_STRING"] = "_method=delete"

    assert_equal "post 1", app.call(env)[2].join
  end

  def test_never_from_a_json_body
    assert_equal "post 1", app.call(request("POST", "application/json", '{"_method":"delete"}'))[2].join
  end

  def test_never_on_another_verb
    assert_equal "patch 1 ", app.call(request("PATCH", "application/x-www-form-urlencoded", "_method=delete"))[2].join
  end

  private

  def request(verb, content_type, body)
    env = env_for(verb, "/items/1")
    env["CONTENT_TYPE"] = content_type
    env["rack.input"] = StringIO.new(body)
    env
  end
end
