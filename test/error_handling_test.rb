require_relative "test_helper"

class ErrorHandlingTest < Minitest::Test
  def test_unhandled_exception_yields_default_500_json_response
    app = Class.new(Monk::Base) do
      get("/x") { raise "boom" }
    end

    status, headers, body = app.call(env_for("GET", "/x"))

    assert_equal 500, status
    assert_equal "application/json", headers["content-type"]
    assert_equal '{"error":"Internal Server Error"}', body.join
  end

  class BoomError < StandardError; end

  def test_registered_error_handler_overrides_default_for_that_exception_class
    app = Class.new(Monk::Base) do
      get("/x") { raise BoomError, "boom" }
      error(BoomError) { halt 422, "custom boom" }
    end

    status, _headers, body = app.call(env_for("GET", "/x"))

    assert_equal 422, status
    assert_equal "custom boom", body.join
  end

  def test_registered_error_handler_defaults_status_to_500_when_using_json
    app = Class.new(Monk::Base) do
      get("/x") { raise BoomError, "boom" }
      error(BoomError) { json(error: "handled") }
    end

    status, _headers, body = app.call(env_for("GET", "/x"))

    assert_equal 500, status
    assert_equal '{"error":"handled"}', body.join
  end

  def test_registered_error_404_handler_sees_env
    app = Class.new(Monk::Base) do
      error(404) { |ctx| ctx.env["PATH_INFO"] }
    end

    _status, _headers, body = app.call(env_for("GET", "/nope"))

    assert_equal "/nope", body.join
  end

  def test_registered_error_404_handler_overrides_default_not_found
    app = Class.new(Monk::Base) do
      error(404) { json(error: "not found") }
    end

    status, headers, body = app.call(env_for("GET", "/nope"))

    assert_equal 404, status
    assert_equal "application/json", headers["content-type"]
    assert_equal '{"error":"not found"}', body.join
  end
end
