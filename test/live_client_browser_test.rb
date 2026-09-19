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
end
