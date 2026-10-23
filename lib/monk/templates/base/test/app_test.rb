require_relative "test_helper"
require "rack/mock_request"

# A request through the booted app, as a browser would make it.
class AppTest < Minitest::Test
  def test_hello
    status, _headers, body = APP.call(Rack::MockRequest.env_for("/hello"))

    assert_equal 200, status
    assert_equal "hello from monk", body.join
  end
end
