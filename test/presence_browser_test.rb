require_relative "test_helper"
require_relative "live_browser_helpers"
require "monk/auth"
require "monk/presence"

# Presence end to end (ADR 0019): a signed-in page in real Chrome, a real
# WebSocket server counting its socket, and this process's presence tick
# against real Postgres. Online while the page is visible, Away once it
# has been hidden for 2 x HEARTBEAT, Offline after the grace once it's
# closed. HEARTBEAT is shortened as protocol.js is served, and the Away
# window with it, in the handler below.
class PresenceBrowserTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthTestHelpers
  include PresenceTestHelpers
  include LiveBrowserHelpers

  DB_NAME = :presence_browser_test_db
  ALLOW = proc { |_subject, _topic| true }
  PAGE = %(<ul data-live-topic="t:1"><li id="a">a</li></ul>).freeze

  # Monk::Live::HANDLER, with the Away window to match a 200 ms heartbeat.
  HANDLER = proc do |connection|
    Monk::Live::Session.new(
      connection, registry: Monk::Live.registry, rules: Monk::Live.rules, max_topics: Monk::Live.max_topics,
      visible_for: 0.8,
    ).run
  end

  # With an Away window far longer than the test: Away can only come from
  # the page saying it's hidden.
  SLOW_SILENCE_HANDLER = proc do |connection|
    Monk::Live::Session.new(
      connection, registry: Monk::Live.registry, rules: Monk::Live.rules, max_topics: Monk::Live.max_topics,
      visible_for: 60,
    ).run
  end

  def setup
    Monk::Persistence::Pg.reset!
    skip_unless_postgres_available
    setup_auth_tables(DB_NAME)
    setup_presence_tables(DB_NAME)
    @store = Monk::Presence::Store.new(db_name: DB_NAME, grace: 1, process_timeout: 30)
    @counts = Monk::Presence::Counts.new(start_visible: false)
    @settled = []
    @tracker = Monk::Presence::Tracker.new(store: @store, counts: @counts).start
    super
    @pages.js_overrides = { "protocol.js" => { "HEARTBEAT = 25000" => "HEARTBEAT = 200" } }
    @subject = sign_in("a@b.com")
  end

  def teardown
    super
    @other_page&.close
    if postgres_available?
      Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
        drop_presence_tables(conn)
        drop_auth_tables(conn)
      end
    end
    Monk::Persistence::Pg.reset!
    Monk::Auth.reset!
  end

  def ws_server_options = { authenticate: true, presence: @counts, ping_interval: 5 }
  # The server starts in setup, before a test's body runs.
  def ws_handler = name == "test_a_hidden_page_says_so_and_reads_away_at_once" ? SLOW_SILENCE_HANDLER : HANDLER

  def test_a_visible_page_is_online_hidden_away_and_online_again_when_shown
    open_page(PAGE)
    wait_for_status(:online)

    hide_page!
    wait_for_status(:away)
    show_page!
    wait_for_status(:online)

    assert_equal [[@subject, :online], [@subject, :away], [@subject, :online]], changes
  end

  def test_a_hidden_page_says_so_and_reads_away_at_once
    open_page(PAGE)
    wait_for_status(:online)

    hide_page!
    wait_for_status(:away)

    assert_equal [[@subject, :online], [@subject, :away]], changes
  end

  def test_a_closed_page_is_offline_after_the_grace_with_last_seen_at
    open_page(PAGE)
    wait_for_status(:online)

    @page.go_to("about:blank")

    status = wait_for_status(:offline)
    refute_nil status[:last_seen_at]
    # Readers see offline as soon as the rows expire, up to a tick before
    # it's settled.
    tick
    assert_equal [[@subject, :online], [@subject, :offline]], changes
  end

  # A hidden tab's reconnect (a deploy, a network change) doesn't make
  # it read as Online: its socket counts as hidden until it pings.
  def test_a_page_hidden_when_it_reconnects_stays_away
    open_page(PAGE)
    wait_for_status(:online)
    hide_page!
    wait_for_status(:away)

    @proxy.sever!
    wait_for("reconnect while hidden") { events("connected").size == 2 }
    3.times do
      tick
      sleep 0.3
    end

    assert_equal :away, Monk::Presence::Store.new(db_name: DB_NAME, grace: 1, process_timeout: 30)
                                             .status([@subject])[@subject][:status]
    assert_equal [[@subject, :online], [@subject, :away]], changes
  end

  private

  def sign_in(email)
    session = Monk::Auth.redeem(Monk::Auth.request_login(email))
    @page.cookies.set(name: "session_token", value: session[:token], domain: "127.0.0.1", path: "/")
    session[:subject]
  end

  def wait_for_status(status)
    found = nil
    wait_for(status.to_s, timeout: 8) do
      tick
      found = @store.status([@subject])[@subject]
      found[:status] == status
    end
    found
  end

  def tick
    @settled.concat(@tracker.tick)
  end

  # The transitions settled so far, as [subject, status].
  def changes = @settled.map { |t| [t.subject, t.status] }

  def hide_page!
    @other_page ||= LiveBrowserHelpers.browser.create_page
    @other_page.command("Page.bringToFront")
    wait_for("hidden") { evaluate("document.visibilityState") == "hidden" }
  end

  def show_page!
    @page.command("Page.bringToFront")
    wait_for("visible") { evaluate("document.visibilityState") == "visible" }
  end
end
