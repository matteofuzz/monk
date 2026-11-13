require_relative "test_helper"
require "rack/mock_request"

# Monk::Push is configured with this environment's VAPID pair (.env.test)
# and reads the table its migration made (bin/setup_db). Someone with no
# subscription gets no notification. SETUP.md, push.
class PushTest < Minitest::Test
  def test_the_key_pair_and_the_table_are_in_place
    subject = "push-check-#{rand(1_000_000)}@example.test"

    assert_equal ENV["VAPID_PUBLIC_KEY"], Monk::Push.public_key
    refute Monk::Push.subscribed?(subject)
    assert_equal 0, Monk::Push.notify(subject, { title: "x" })
  end

  def test_pages_give_the_browser_the_key_and_the_client
    _status, _headers, body = APP.call(Rack::MockRequest.env_for("/"))
    html = body.to_enum(:each).to_a.join

    assert_includes html, %(<meta name="monk-push-key" content="#{ENV["VAPID_PUBLIC_KEY"]}">)
    assert_match %r{<script type="module" src="/_monk/push/push\.js[^"]*"></script>}, html
  end
end
