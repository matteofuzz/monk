require_relative "test_helper"
require_relative "live_browser_helpers"
require_relative "live_multiprocess_helpers_pg"

# The whole stack over Postgres, two processes: Chrome loads a page from
# this process, and its WebSocket goes to a separate Monk::Live process
# relaying through PgFanout. Here that process's LISTEN connection is
# dropped (plan-pg-reconnect.md, phase 5).
class LivePgBrowserTest < Minitest::Test
  include LiveBrowserPage
  include LiveMultiprocessHelpersPg

  def setup
    skip_unless_postgres_available
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

  # Whatever was published while the listener was down is lost, and the
  # page can't tell. The WS process closes its socket with 1011 once it
  # listens again, so the page reconnects, refetches, and shows the
  # change it missed; later patches arrive as usual.
  def test_a_dropped_listen_connection_makes_open_pages_resync
    topic = unique_topic
    open_page(%(<ul data-live-topic="#{topic}"><li id="c-1">before</li></ul>))
    @pages.serve_page(page_html(%(<ul data-live-topic="#{topic}"><li id="c-1">missed</li></ul>)))

    terminate_backend(ws_listen_pid)

    wait_for("reconnect + resync") { events("resynced").size == 1 }
    assert_equal "missed", evaluate("document.querySelector('#c-1').textContent")
    assert_equal 1, events("disconnected").size

    @publisher.remove(topic, to: "#c-1")
    wait_for("a patch after the resync") { evaluate("document.querySelector('#c-1') === null") }
  end
end
