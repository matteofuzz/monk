require_relative "test_helper"
require_relative "live_browser_helpers"

class LiveClientBrowserTest < Minitest::Test
  ALLOW = proc { |_subject, _topic| true }

  include LiveBrowserHelpers

  ROW = %(<li id="contact-<%= locals[:id] %>" class="<%= locals[:status] %>"><%= locals[:name] %></li>).freeze

  def test_it_subscribes_from_data_live_topic_and_morphs_a_patch_into_the_page
    with_frozen_views({ "row.erb" => ROW }) do
      open_page(%(<ul id="contacts" data-live-topic="t:1"><li id="contact-1" class="on">Ada</li></ul>))
      assert_equal [{ "topics" => ["t:1"], "denied" => [] }], events("subscribed")

      @publisher.patch("t:1", to: "#contact-1", partial: "row", id: 1, status: "away", name: "Ada L.")

      wait_for("patch") { evaluate("document.querySelector('#contact-1').className") == "away" }
      assert_equal "Ada L.", evaluate("document.querySelector('#contact-1').textContent")
      assert_equal [{ "target" => "#contact-1", "mode" => "morph", "matched" => 1 }], events("patched")
    end
  end

  def test_a_patch_keeps_focus_text_and_selection_in_a_sibling_and_inside_the_patched_node
    row = %(<li id="contact-1">row <input id="inner" placeholder="x"> <%= locals[:tick] %></li>)
    with_frozen_views({ "row.erb" => row }) do
      open_page(<<~HTML)
        <input id="outside">
        <ul data-live-topic="t:1"><li id="contact-1">row <input id="inner" placeholder="x"> 0</li></ul>
      HTML
      run_js(<<~JS)
        const o = document.querySelector('#outside');
        o.focus(); o.value = 'hello world'; o.setSelectionRange(2, 5);
      JS
      @publisher.patch("t:1", to: "#contact-1", partial: "row", tick: 1)
      wait_for("first patch") { evaluate("document.querySelector('#contact-1').textContent.includes('1')") }

      assert_equal ["outside", "hello world", 2, 5],
        run_js("const o = document.activeElement; return [o.id, o.value, o.selectionStart, o.selectionEnd];")

      run_js(<<~JS)
        const i = document.querySelector('#inner');
        i.focus(); i.value = 'typing'; i.setSelectionRange(1, 4); window.__inner = i;
      JS
      @publisher.patch("t:1", to: "#contact-1", partial: "row", tick: 2)
      wait_for("second patch") { evaluate("document.querySelector('#contact-1').textContent.includes('2')") }

      assert_equal [true, "typing", 1, 4],
        run_js(<<~JS)
          const i = document.activeElement;
          return [i === window.__inner, i.value, i.selectionStart, i.selectionEnd];
        JS
    end
  end

  def test_data_live_ignore_subtrees_and_open_details_are_not_clobbered
    template = %(<li id="contact-1">server <span id="widget" data-live-ignore>SERVER</span> ) +
               %(<details id="more"><summary>more</summary>bio</details> <%= locals[:tick] %></li>)
    with_frozen_views({ "row.erb" => template }) do
      open_page(<<~HTML)
        <ul data-live-topic="t:1"><li id="contact-1">server <span id="widget" data-live-ignore>LOCAL</span>
        <details id="more"><summary>more</summary>bio</details> 0</li></ul>
      HTML
      run_js(<<~JS)
        document.querySelector('#more').open = true;
        document.querySelector('#widget').textContent = 'LOCAL-EDIT';
      JS

      @publisher.patch("t:1", to: "#contact-1", partial: "row", tick: 1)

      wait_for("patch") { evaluate("document.querySelector('#contact-1').textContent.includes('1')") }
      assert_equal "LOCAL-EDIT", evaluate("document.querySelector('#widget').textContent")
      assert evaluate("document.querySelector('#more').open"), "a patch closed a <details> the user opened"
    end
  end

  def test_every_mode_a_multi_match_target_and_a_batch
    with_frozen_views({ "row.erb" => ROW }) do
      open_page(%(<ul id="list" data-live-topic="t:1"><li class="dot">a</li><li class="dot">b</li></ul>))

      @publisher.batch("t:1") do |batch|
        batch.patch(to: ".dot", partial: "row", id: 9, status: "on", name: "morphed")
        batch.append(to: "#list", partial: "row", id: 3, status: "x", name: "last")
        batch.prepend(to: "#list", partial: "row", id: 0, status: "x", name: "first")
        batch.remove(to: "#contact-3")
      end

      wait_for("batch") { evaluate("document.querySelector('#contact-0') !== null") }
      assert_equal ["first", "morphed", "morphed"],
        evaluate("[...document.querySelectorAll('#list li')].map(li => li.textContent)")
      assert_equal 4, events("patched").size
    end
  end

  def test_a_denied_topic_is_reported_and_never_patched
    Monk::Live.reset!
    Monk::Live.configure(registry: @registry)
    Monk::Live.authorize("t:ok", anonymous: true, &ALLOW)
    with_frozen_views({ "row.erb" => ROW }) do
      open_page(%(<ul data-live-topic="t:ok t:secret"><li id="contact-1">a</li></ul>))

      assert_equal [{ "topics" => ["t:ok"], "denied" => ["t:secret"] }], events("subscribed")
      assert_equal 0, @registry.count(:"t:secret")
    end
  end

  def test_a_page_without_topics_never_connects
    open_page("<p>nothing live here</p>", topics_ready: false)
    sleep 0.5

    assert_equal 0, @proxy.connections
  end

  def test_a_lost_frame_is_detected_by_seq_and_the_page_is_refetched
    with_frozen_views({ "row.erb" => ROW }) do
      open_page(%(<ul data-live-topic="t:1"><li id="contact-1" class="old">old</li></ul>))
      @publisher.remove("t:1", to: "#nothing")
      wait_for("first frame") { events("patched").size == 1 }

      @pages.serve_page(page_html(%(<ul data-live-topic="t:1"><li id="contact-1" class="fresh">fresh</li></ul>)))
      @proxy.drop_next_server_frame!
      @publisher.remove("t:1", to: "#nothing")
      @publisher.remove("t:1", to: "#nothing")

      wait_for("resync") { events("resynced").size == 1 }
      assert_equal "fresh", evaluate("document.querySelector('#contact-1').textContent")
      assert_equal [{ "seq" => 3 }], events("gap")
    end
  end

  def test_a_dropped_connection_reconnects_resubscribes_and_resyncs_missed_changes
    open_page(%(<ul data-live-topic="t:1"><li id="contact-1">before</li></ul>))
    @pages.serve_page(page_html(%(<ul data-live-topic="t:1"><li id="contact-1">after</li></ul>)))

    @proxy.sever!

    wait_for("reconnect + resync") { events("resynced").size == 1 }
    assert_equal "after", evaluate("document.querySelector('#contact-1').textContent")
    assert_equal 1, events("disconnected").size
    assert_equal 2, events("connected").size
    assert_equal 1, @registry.count(:"t:1")
  end

  def test_a_resync_that_brings_new_topics_subscribes_to_them
    open_page(%(<ul data-live-topic="t:1"><li>a</li></ul>))
    @pages.serve_page(page_html(%(<ul data-live-topic="t:1"><li>a</li></ul><ol data-live-topic="t:2"></ol>)))

    @proxy.sever!

    wait_for("new topic registered") { @registry.count(:"t:2") == 1 }
  end

  def test_a_resync_answered_with_a_redirect_stops_the_runtime_and_leaves_the_page_alone
    open_page(%(<ul data-live-topic="t:1"><li id="contact-1">mine</li></ul>))
    @pages.serve_page("", status: 302, headers: { "location" => "/login" })

    @proxy.sever!

    wait_for("stop") { events("stopped").size == 1 }
    assert_equal [{ "reason" => "redirected" }], events("stopped")
    assert_equal "mine", evaluate("document.querySelector('#contact-1').textContent")
    connections = @proxy.connections
    sleep 1.5
    assert_equal connections, @proxy.connections, "the runtime kept reconnecting after it stopped"
  end

  # --- Phase 5: the refetch morph is a whole-body morph, so it has to honor
  # the same protections a single patch does. ---

  def test_a_resync_keeps_focus_typed_text_ignored_subtrees_and_open_details
    open_page(resync_page(status: "before", widget: "LOCAL", note: "old"))
    run_js(<<~JS)
      const i = document.querySelector('#draft');
      i.focus(); i.value = 'half-typed'; i.setSelectionRange(2, 6); window.__draft = i;
      document.querySelector('#more').open = true;
      document.querySelector('#widget').textContent = 'LOCAL-EDIT';
    JS
    @pages.serve_page(page_html(resync_page(status: "after", widget: "SERVER", note: "new")))

    @proxy.sever!

    wait_for("resync") { events("resynced").size == 1 }
    assert_equal ["after", "new"],
      evaluate("[document.querySelector('#status').textContent, document.querySelector('#note').textContent]")
    assert_equal [true, "half-typed", 2, 6],
      run_js(<<~JS)
        const i = document.activeElement;
        return [i === window.__draft, i.value, i.selectionStart, i.selectionEnd];
      JS
    assert_equal "LOCAL-EDIT", evaluate("document.querySelector('#widget').textContent")
    assert evaluate("document.querySelector('#more').open"), "the resync closed a <details> the user opened"
  end

  def test_a_resync_answered_with_an_error_or_a_non_html_page_stops_and_leaves_the_page_alone
    { 401 => "status_401", 500 => "status_500" }.each do |status, reason|
      assert_stops_with(reason) { @pages.serve_page("nope", status: status) }
    end
    assert_stops_with("not_html") do
      @pages.serve_page('{"ok":true}', headers: { "content-type" => "application/json" })
    end
  end

  def test_a_failed_resync_is_retried_with_backoff_until_it_works
    open_page(%(<ul data-live-topic="t:1"><li id="contact-1">before</li></ul>))
    @pages.serve_page("", drop: true)
    @proxy.sever!
    wait_for("failed resync") { events("resync-failed").size >= 1 }

    @pages.serve_page(page_html(%(<ul data-live-topic="t:1"><li id="contact-1">recovered</li></ul>)))

    wait_for("retry", timeout: 10) { events("resynced").size == 1 }
    assert_equal "recovered", evaluate("document.querySelector('#contact-1').textContent")
  end

  def test_overlapping_resync_triggers_coalesce_into_one_follow_up_fetch
    with_frozen_views({ "row.erb" => ROW }) do
      open_page(%(<ul data-live-topic="t:1"><li id="contact-1">v0</li></ul>))
      @pages.serve_page(page_html(%(<ul data-live-topic="t:1"><li id="contact-1">v1</li></ul>)), delay: 1.0)
      hits_before = @pages.page_hits

      @proxy.sever!
      wait_for("resync fetch in flight") { @pages.page_hits == hits_before + 1 }
      wait_for("resubscribed") { @registry.count(:"t:1") == 1 }
      3.times do |n|
        @proxy.drop_next_server_frame!
        @publisher.remove("t:1", to: "#nothing")
        @publisher.remove("t:1", to: "#nothing")
        wait_for("gap #{n + 1}") { events("gap").size == n + 1 } # one lost frame at a time
      end

      wait_for("resyncs done", timeout: 10) { events("resynced").size >= 2 }
      sleep 1.5
      assert_equal 3, events("gap").size
      assert_equal 2, events("resynced").size, "overlapping triggers were not coalesced"
      assert_equal hits_before + 2, @pages.page_hits, "more page fetches than the in-flight one plus one follow-up"
    end
  end

  def test_a_resync_of_a_large_page_converges_and_keeps_the_focused_input
    rows = lambda { |label|
      (1..800).map do |n|
        %(<li id="row-#{n}" class="r">#{label} #{n} <input id="in-#{n}"></li>)
      end.join
    }
    open_page(%(<ul data-live-topic="t:1">#{rows.call("old")}</ul>))
    run_js("const i = document.querySelector('#in-400'); i.focus(); i.value = 'keep me'; window.__in = i;")
    @pages.serve_page(page_html(%(<ul data-live-topic="t:1">#{rows.call("new")}</ul>)))

    @proxy.sever!

    wait_for("large resync", timeout: 15) { events("resynced").size == 1 }
    subscribed_at, resynced_at = evaluate(
      "[window.__events.filter(e => e.name === 'subscribed').at(-1).at, " \
      "window.__events.find(e => e.name === 'resynced').at]",
    )
    puts "\n  [800-row resync: fetch+parse+morph #{(resynced_at - subscribed_at).round}ms]" if ENV["MONK_TEST_VERBOSE"]
    assert_equal ["new 800", 800],
      evaluate("[document.querySelector('#row-800').firstChild.textContent.trim(), " \
               "document.querySelectorAll('.r').length]")
    assert_equal [true, "keep me"], run_js("return [document.activeElement === window.__in, window.__in.value];")
  end

  private

  def resync_page(status:, widget:, note:)
    <<~HTML
      <div data-live-topic="t:1">
        <p id="status">#{status}</p><p id="note">#{note}</p>
        <input id="draft"> <span id="widget" data-live-ignore>#{widget}</span>
        <details id="more"><summary>more</summary>bio</details>
      </div>
    HTML
  end

  # Opens a live page, makes the next page fetch answer with whatever the
  # block serves, cuts the connection, and expects the runtime to stop with
  # `reason` and leave the page exactly as it was.
  def assert_stops_with(reason)
    @page.close
    @pages.serve_page(page_html(%(<ul data-live-topic="t:1"><li id="contact-1">mine</li></ul>)))
    @page = LiveBrowserHelpers.browser.create_page
    @page.go_to("http://127.0.0.1:#{@pages.port}/page")
    wait_for("client subscribed") { evaluate("window.__events.some(e => e.name === 'subscribed')") }
    yield

    @proxy.sever!

    wait_for("stop") { events("stopped").size == 1 }
    assert_equal [{ "reason" => reason }], events("stopped")
    assert_equal "mine", evaluate("document.querySelector('#contact-1').textContent")
    connections = @proxy.connections
    sleep 1.2
    assert_equal connections, @proxy.connections, "the runtime kept reconnecting after it stopped"
  end
end
