require_relative "test_helper"

class CrossOriginTest < Minitest::Test
  def app
    Class.new(Monk::Base) do
      get("/x") { "get" }
      post("/x") { "post" }
      delete("/x") { "delete" }
      post("/hook", allow_cross_origin: true) { "hook" }
    end
  end

  def test_same_origin_and_user_initiated_requests_pass
    assert_equal 200, call("POST", "/x", "HTTP_SEC_FETCH_SITE" => "same-origin")
    assert_equal 200, call("POST", "/x", "HTTP_SEC_FETCH_SITE" => "none")
  end

  def test_cross_site_and_same_site_requests_are_refused
    assert_equal 403, call("POST", "/x", "HTTP_SEC_FETCH_SITE" => "cross-site")
    assert_equal 403, call("POST", "/x", "HTTP_SEC_FETCH_SITE" => "same-site")
    assert_equal 403, call("DELETE", "/x", "HTTP_SEC_FETCH_SITE" => "cross-site")
  end

  def test_sec_fetch_site_wins_over_origin
    assert_equal 403, call("POST", "/x", "HTTP_SEC_FETCH_SITE" => "cross-site",
      "HTTP_ORIGIN" => "https://app.example", "HTTP_HOST" => "app.example",)
  end

  def test_without_sec_fetch_site_origin_must_match_host
    assert_equal 200, call("POST", "/x", "HTTP_ORIGIN" => "https://app.example", "HTTP_HOST" => "app.example")
    assert_equal 200, call("POST", "/x", "HTTP_ORIGIN" => "http://localhost:9292", "HTTP_HOST" => "localhost:9292")
    assert_equal 403, call("POST", "/x", "HTTP_ORIGIN" => "https://evil.example", "HTTP_HOST" => "app.example")
    assert_equal 403, call("POST", "/x", "HTTP_ORIGIN" => "null", "HTTP_HOST" => "app.example")
  end

  def test_a_request_with_neither_header_passes
    assert_equal 200, call("POST", "/x")
  end

  def test_get_is_never_checked
    assert_equal 200, call("GET", "/x", "HTTP_SEC_FETCH_SITE" => "cross-site")
  end

  def test_a_route_can_allow_cross_origin_requests
    assert_equal 200, call("POST", "/hook", "HTTP_SEC_FETCH_SITE" => "cross-site")
  end

  def test_an_overridden_verb_is_checked_too
    env = env_for("POST", "/x").merge("HTTP_SEC_FETCH_SITE" => "cross-site",
      "CONTENT_TYPE" => "application/x-www-form-urlencoded", "rack.input" => StringIO.new("_method=delete"),)

    assert_equal 403, app.call(env).first
  end

  private

  def call(verb, path, headers = {})
    app.call(env_for(verb, path).merge(headers)).first
  end
end
