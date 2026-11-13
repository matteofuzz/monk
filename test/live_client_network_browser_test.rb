require_relative "test_helper"
require_relative "live_browser_helpers"

# The Live client on real networks (docs/plan-live-networks-presence.md,
# A2-A3): its heartbeat, and what it does when the page is hidden, shown,
# offline, online, frozen or restored from the back/forward cache. Real
# Chrome, with the heartbeat shortened as protocol.js is served.
class LiveClientNetworkBrowserTest < Minitest::Test
  ALLOW = proc { |_subject, _topic| true }
  PAGE = %(<ul data-live-topic="t:1"><li id="contact-1">before</li></ul>).freeze
  AFTER = %(<ul data-live-topic="t:1"><li id="contact-1">after</li></ul>).freeze

  include LiveBrowserHelpers

  def setup
    super
    @pages.js_overrides = {
      "protocol.js" => { "HEARTBEAT = 25000" => "HEARTBEAT = 300", "PONG_TIMEOUT = 10000" => "PONG_TIMEOUT = 300" },
    }
  end

  def teardown
    @other_page&.close
    super
  end

  # A phone whose network went away under it: nothing closes, nothing
  # arrives. The client gives up on its own instead of waiting for onclose.
  def test_a_silent_socket_is_given_up_on_and_the_page_reconnects_and_resyncs
    open_page(PAGE)
    @pages.serve_page(page_html(AFTER))

    @proxy.blackhole!

    wait_for("stale") { events("stale").size == 1 }
    assert_equal [{ "reason" => "timeout" }], events("disconnected")
    wait_for("reconnect + resync") { events("resynced").size == 1 }
    assert_equal "after", evaluate("document.querySelector('#contact-1').textContent")
  end

  def test_the_late_close_of_a_socket_given_up_on_starts_no_second_connection
    open_page(PAGE)
    @proxy.blackhole!
    wait_for("reconnect") { events("connected").size == 2 }

    @proxy.release_blackholed!
    sleep 0.5

    assert_equal 2, events("connected").size
    assert_equal 1, events("disconnected").size
    assert_equal 2, @proxy.connections
  end

  def test_an_answering_socket_stays_open
    open_page(PAGE)

    sleep 1.5 # five heartbeats

    assert_empty events("stale")
    assert_equal 1, events("connected").size
  end

  # Throttled timers would fire the timeout late and wrongly, and pings
  # stopping is how presence will tell a hidden page (open question 6).
  def test_a_hidden_page_sends_no_pings_and_probes_when_shown
    open_page(PAGE)
    hide_page!
    sent = @proxy.upstream_bytes

    sleep 1

    assert_equal sent, @proxy.upstream_bytes, "expected no frames from a hidden page"
    show_page!
    wait_for("probe") { @proxy.upstream_bytes > sent }
    assert_equal 1, events("connected").size
  end

  def test_a_hidden_page_reconnects_once_then_waits_to_be_shown
    open_page(PAGE)
    hide_page!

    @proxy.sever!
    wait_for("one reconnect while hidden") { events("connected").size == 2 }
    @proxy.sever!
    sleep 2 # past two backoff steps

    assert_equal 2, events("connected").size
    assert_equal 2, @proxy.connections
    show_page!
    wait_for("reconnect when shown", timeout: 2) { events("connected").size == 3 }
  end

  def test_a_dead_socket_found_when_shown_reconnects_without_waiting_out_the_backoff
    open_page(PAGE)
    @pages.serve_page(page_html(AFTER))
    hide_page!
    @proxy.blackhole!

    show_page!

    wait_for("stale", timeout: 2) { events("stale").size == 1 }
    wait_for("reconnect + resync", timeout: 3) { events("resynced").size == 1 }
  end

  def test_offline_stops_reconnecting_and_online_reconnects_at_once
    open_page(PAGE)
    @page.command("Network.enable")
    emulate_offline(true)
    wait_for("offline") { evaluate("navigator.onLine") == false }

    @proxy.sever!
    sleep 4 # backoff steps of 0.5, 1 and 2 s: the delay is past 4 s now

    assert_equal 1, evaluate("window.__sockets"), "expected no attempt while offline"
    emulate_offline(false)
    wait_for("reconnect when online", timeout: 1.5) { events("connected").size == 2 }
  end

  # Monk sends no Cache-Control on HTML, so Chrome may keep a page in its
  # back/forward cache; the socket is gone when it comes back.
  def test_a_page_restored_from_the_back_forward_cache_reconnects_and_resyncs
    @pages.cache_control = nil
    open_page(PAGE)
    evaluate("window.__marker = 42")
    @pages.serve_page(page_html(AFTER))

    @page.go_to("http://127.0.0.1:#{@pages.port}/login")
    @page.back

    assert evaluate("window.__marker === 42"), "expected the page restored from the back/forward cache"
    wait_for("reconnect + resync") { events("resynced").size == 1 }
    assert_includes events("disconnected"), { "reason" => "restored" }
    assert_equal "after", evaluate("document.querySelector('#contact-1').textContent")
  end

  private

  def hide_page!
    @other_page ||= LiveBrowserHelpers.browser.create_page
    @other_page.command("Page.bringToFront")
    wait_for("hidden") { evaluate("document.visibilityState") == "hidden" }
  end

  def show_page!
    @page.command("Page.bringToFront")
    wait_for("visible") { evaluate("document.visibilityState") == "visible" }
  end

  def emulate_offline(offline)
    @page.command("Network.emulateNetworkConditions", offline: offline, latency: 0, downloadThroughput: -1,
      uploadThroughput: -1,)
  end
end
