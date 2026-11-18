require_relative "test_helper"
require "json"
require "rack/mock_request"

# The app is installable (monk add pwa): the manifest, the icons it names
# and the service worker are served, and pages link them. SETUP.md, pwa.
class PwaTest < Minitest::Test
  def test_the_manifest_its_icons_and_the_service_worker_are_served
    status, headers, body = get("/manifest.webmanifest")
    assert_equal 200, status
    assert_equal "application/manifest+json; charset=utf-8", headers["content-type"]

    JSON.parse(body)["icons"].each { |icon| assert_equal 200, get(icon["src"]).first, icon["src"] }
    assert_equal 200, get("/sw.js").first
  end

  def test_pages_link_the_manifest_and_register_the_service_worker
    _status, _headers, body = get("/")

    assert_includes body, %(<link rel="manifest" href="/manifest.webmanifest">)
    assert_match %r{<script type="module" src="/_monk/pwa/register\.js[^"]*"></script>}, body
  end

  private

  def get(path)
    status, headers, body = APP.call(Rack::MockRequest.env_for(path))
    [status, headers, body.to_enum(:each).to_a.join]
  end
end
