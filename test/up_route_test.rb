require_relative "test_helper"

# GET /_monk/up: "the process answers requests", for a deploy's health
# check and for the offline client's retry. Answered before routing:
# no route, session or database runs, and it isn't logged.
class UpRouteTest < Minitest::Test
  def app
    Class.new(Monk::Base) do
      # Would answer every path, and fail, if /_monk/up reached routing.
      get("/*") { raise "routing ran" }
    end
  end

  def test_get_answers_204_with_no_body_and_no_store
    status, headers, body = app.call(env_for("GET", "/_monk/up"))

    assert_equal 204, status
    assert_equal "no-store", headers["cache-control"]
    assert_empty body.to_a.join
    assert_equal "nosniff", headers["x-content-type-options"]
    refute headers.key?("set-cookie")
  end

  def test_head_answers_too
    assert_equal 204, app.call(env_for("HEAD", "/_monk/up")).first
  end

  def test_other_methods_are_refused
    status, headers, _body = app.call(env_for("POST", "/_monk/up"))

    assert_equal 405, status
    assert_equal "GET, HEAD", headers["allow"]
  end

  def test_it_is_not_logged
    with_log do |dir|
      app.call(env_for("GET", "/_monk/up"))

      assert_empty Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) }.map { |f| File.read(f) }.join
    end
  end

  def test_other_paths_still_route
    assert_equal 500, app.call(env_for("GET", "/_monk/upper")).first
  end
end
