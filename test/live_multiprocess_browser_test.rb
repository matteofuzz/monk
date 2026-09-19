require_relative "test_helper"
require_relative "live_browser_helpers"
require_relative "live_multiprocess_helpers"

# The whole stack, two processes: Chrome loads a page from this process, its
# WebSocket connection goes to a separate Monk::Live process, and a patch
# rendered and published here (through RedisFanout) morphs the open page.
class LiveMultiprocessBrowserTest < Minitest::Test
  include LiveBrowserPage
  include LiveMultiprocessHelpers

  ROW = %(<li id="c-1" class="<%= locals[:status] %>"><%= locals[:text] %></li>).freeze

  def setup
    skip_unless_redis_available
    skip "Ferrum/Chrome not available" unless LiveBrowserHelpers.browser

    start_ws_process
    build_publisher
    @proxy = LiveBrowserHelpers::WsProxy.new(@ws_port)
    @pages = LiveBrowserHelpers::PageServer.new
    @page = LiveBrowserHelpers.browser.create_page
  end

  def teardown
    @page&.close
    @pages&.close
    @proxy&.close
    stop_ws_process
  end

  def test_a_patch_published_in_one_process_morphs_a_page_served_by_another_view_of_the_stack
    with_frozen_views({ "row.erb" => ROW }) do
      topic = unique_topic
      open_page(%(<ul data-live-topic="#{topic}"><li id="c-1" class="on">Ada</li></ul>))

      @publisher.patch(topic, to: "#c-1", partial: "row", status: "away", text: "Ada, café ☃")

      wait_for("cross-process patch") { evaluate("document.querySelector('#c-1').className") == "away" }
      assert_equal "Ada, café ☃", evaluate("document.querySelector('#c-1').textContent")
      assert_equal [{ "target" => "#c-1", "mode" => "morph", "matched" => 1 }], events("patched")
    end
  end

  def test_killing_the_ws_process_makes_the_client_stop_patching_and_keep_retrying_without_breaking_the_page
    topic = unique_topic
    open_page(%(<ul data-live-topic="#{topic}"><li id="c-1">still here</li></ul>))

    stop_ws_process
    @ws_pid = nil

    wait_for("disconnect noticed") { events("disconnected").size >= 1 }
    assert_equal "still here", evaluate("document.querySelector('#c-1').textContent")
    assert_empty events("stopped")
  end
end
