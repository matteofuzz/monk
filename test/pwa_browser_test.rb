require_relative "test_helper"
require "socket"
require "pg"

# A generated app with pwa (monk new shop --with pwa), served by its own
# bin/server, in real headless Chrome: Chrome registers /sw.js for the
# whole site and finds nothing stopping it installing the app, from the
# files exactly as monk add writes them (docs/history/plan-pwa-push.md, A4).
class PwaBrowserTest < Minitest::Test
  include GeneratorTestHelpers
  include PersistenceTestHelpers

  IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) " \
           "Version/26.6 Mobile/15E148 Safari/604.1".freeze
  ANDROID = "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 " \
            "Mobile Safari/537.36".freeze

  # Its own Chrome, not the Live tests' one: Ferrum opens every page in a
  # new browser context, which Chrome treats as incognito, and in incognito
  # getInstallabilityErrors stops at "in-incognito" without checking the
  # manifest. So this one keeps its startup profile (incognito: false) and
  # opens its page there, through a Ferrum::Context for Chrome's default
  # context (Ferrum has no public call for it).
  def self.browser
    return @browser if defined?(@browser)

    @browser =
      begin
        require "ferrum"
        Ferrum::Browser.new(headless: :new, timeout: 20, process_timeout: 30, incognito: false,
          browser_options: ChromeOptions.browser_options,).tap do |browser|
          at_exit { browser.quit }
        end
      rescue LoadError, StandardError
        nil
      end
  end

  def setup
    browser = self.class.browser
    skip "needs Ferrum and Chrome" unless browser
    @page = default_profile_page(browser)
  end

  def teardown
    @page&.close
  end

  def test_chrome_registers_the_service_worker_and_can_install_the_app
    with_new_app(:pwa) do |dest|
      with_server(dest) do |port|
        @page.go_to("http://127.0.0.1:#{port}/")

        scope = @page.evaluate_async(<<~JS, 10)
          navigator.serviceWorker.ready.then((registration) => arguments[0](registration.scope))
        JS
        assert_equal "http://127.0.0.1:#{port}/", scope

        manifest = @page.command("Page.getAppManifest")
        assert_empty manifest["errors"], manifest["errors"].inspect
        assert_includes manifest["data"], %("name": "shop")

        errors = @page.command("Page.getInstallabilityErrors")["installabilityErrors"]
        assert_empty errors, errors.inspect
      end
    end
  end

  # With the worker in control, requests still reach the app: its fetch
  # handler takes page loads only, never a fetch like Live's resync.
  def test_a_controlled_page_still_fetches_from_the_app
    with_new_app(:pwa) do |dest|
      with_server(dest) do |port|
        @page.go_to("http://127.0.0.1:#{port}/")
        @page.evaluate_async("navigator.serviceWorker.ready.then(() => arguments[0](true))", 10)
        @page.refresh

        assert @page.evaluate("navigator.serviceWorker.controller !== null"), "the reloaded page is controlled"
        body = @page.evaluate_async("fetch('/hello').then((r) => r.text()).then(arguments[0])", 10)
        assert_equal "hello from monk", body
      end
    end
  end

  # sw.js's push handler, given a message the way a push service hands it
  # over (DevTools delivers it straight to the worker): it shows the
  # message as a notification, its url kept for the click.
  def test_a_push_message_becomes_a_notification
    with_new_app(:pwa) do |dest|
      with_server(dest) do |port|
        origin = "http://127.0.0.1:#{port}"
        @page.command("Browser.grantPermissions", origin: origin, permissions: ["notifications"])
        @page.go_to("#{origin}/")
        @page.evaluate_async("navigator.serviceWorker.ready.then(() => arguments[0](true))", 10)
        registration_id = wait_for_registration_id(origin)

        message = { title: "Ann", body: "Lunch?", url: "/chats/7", tag: "chat-7" }.to_json
        @page.command("ServiceWorker.deliverPushMessage", origin: "#{origin}/", registrationId: registration_id,
          data: message,)

        shown = wait_for_notifications
        assert_equal [["Ann", "Lunch?", "chat-7", "/chats/7"]], shown
      end
    end
  end

  # A page running as the installed app tells sw.js so (register.js posts
  # it; headless Chrome is never standalone, so the page posts it here),
  # and the worker records the window and that the app is installed, for
  # a notification's click (test/js/sw_click.test.js has the choice itself).
  def test_the_worker_records_a_window_of_the_installed_app
    with_new_app(:pwa) do |dest|
      with_server(dest) do |port|
        @page.go_to("http://127.0.0.1:#{port}/")
        @page.evaluate_async(<<~JS, 10)
          navigator.serviceWorker.ready
            .then((r) => r.active.postMessage({ monkPwa: { standalone: true } }))
            .then(() => arguments[0](true))
        JS

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        paths = []
        loop do
          paths = @page.evaluate_async(<<~JS, 10)
            caches.open("monk-pwa-app-windows").then((c) => c.keys())
              .then((keys) => arguments[0](keys.map((k) => new URL(k.url).pathname).sort()))
          JS
          break if paths.size == 2 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.05
        end
        assert_match %r{\A/_monk/pwa/app-window/.+\z}, paths[0]
        assert_equal "/_monk/pwa/installed", paths[1]
      end
    end
  end

  # The installed iPhone app asks once for its own session (decision 9 of
  # docs/plan-onboarding.md). Headless Chrome is never standalone, so the
  # page is told it is; the app's /auth/own is a probe recording each call.
  def test_the_installed_iphone_app_asks_once_for_its_own_session
    with_own_session_probe do |origin, calls|
      pretend_standalone
      @page.command("Network.setCookie", name: "csrf_token", value: "csrf-abc", url: origin)

      @page.go_to("#{origin}/own-probe")
      wait_until { calls.call.size == 1 }
      assert_equal ["csrf-abc"], calls.call
      wait_until { @page.evaluate("localStorage.getItem('monk-pwa:own-session')") == "1" }

      @page.refresh
      settle
      assert_equal 1, calls.call.size, "remembered: not asked again"
    end
  end

  def test_a_failed_ask_is_tried_again_on_the_next_launch
    with_own_session_probe do |origin, calls, dest|
      pretend_standalone
      File.write(File.join(dest, "tmp/own_status"), "500")

      @page.go_to("#{origin}/own-probe")
      wait_until { calls.call.size == 1 }
      settle
      assert_nil @page.evaluate("localStorage.getItem('monk-pwa:own-session')")

      File.delete(File.join(dest, "tmp/own_status"))
      @page.refresh
      wait_until { calls.call.size == 2 }
    end
  end

  def test_a_browser_tab_never_asks
    with_own_session_probe do |origin, calls|
      @page.go_to("#{origin}/own-probe")
      settle

      assert_empty calls.call
    end
  end

  # register.js tells the page where it runs, and <%= monk_install %>'s
  # banner follows (docs/plan-onboarding.md, decisions 11-12).
  def test_on_a_desktop_the_page_learns_it_and_the_banner_stays_hidden
    with_install_probe do |origin|
      @page.go_to("#{origin}/install-probe")
      wait_until { root_data("pwaPlatform") }

      assert_equal "other", root_data("pwaPlatform")
      assert_equal "false", root_data("pwaStandalone")
      assert_nil root_data("pwaInApp")
      assert @page.evaluate("document.querySelector('[data-monk-install-banner]').hidden")
    end
  end

  def test_on_an_iphone_the_banner_shows_and_its_button_opens_the_sheet
    with_install_probe do |origin|
      user_agent(IPHONE)
      @page.go_to("#{origin}/install-probe")
      wait_until { root_data("pwaPlatform") == "ios" }

      refute @page.evaluate("document.querySelector('[data-monk-install-banner]').hidden")
      @page.evaluate("document.querySelector('[data-monk-install]').click()")
      assert @page.evaluate("document.querySelector('[data-monk-install-sheet]').open")
    end
  end

  def test_a_social_apps_built_in_browser_is_marked
    with_install_probe do |origin|
      user_agent("#{IPHONE} Instagram 380.0.0.0.0")
      @page.go_to("#{origin}/install-probe")
      wait_until { root_data("pwaPlatform") }

      assert_equal "", root_data("pwaInApp")
    end
  end

  # Chrome's prompt, as a page gets it: the test fires the event, and a
  # script run before the page's own gives it a stand-in prompt().
  def test_on_android_the_browsers_prompt_shows_the_banner_and_its_button_opens_it
    with_install_probe do |origin|
      user_agent(ANDROID)
      @page.command("Page.addScriptToEvaluateOnNewDocument", source: <<~JS)
        addEventListener("beforeinstallprompt", (event) => {
          event.prompt = () => { window.prompted = true; };
        });
      JS
      @page.go_to("#{origin}/install-probe")
      wait_until { root_data("pwaPlatform") == "android" }

      @page.execute(<<~JS)
        document.addEventListener("monk-pwa:installable", () => { window.installableSeen = true; });
        window.dispatchEvent(new Event("beforeinstallprompt", { cancelable: true }));
      JS

      assert_equal "", root_data("pwaInstallable")
      assert @page.evaluate("window.installableSeen")
      refute @page.evaluate("document.querySelector('[data-monk-install-banner]').hidden")
      @page.evaluate("document.querySelector('[data-monk-install]').click()")
      assert @page.evaluate("window.prompted")
      refute @page.evaluate("document.querySelector('[data-monk-install-sheet]').open")
    end
  end

  # --- offline, level 0 (docs/plan-0-29.md, part 2) ---

  # The network gone with a page open: after the delay, <html> and the
  # banner say "network", and a link to another page is cancelled. Back
  # online, both go.
  def test_offline_with_a_page_open_shows_the_banner_and_blocks_links
    with_offline_probe do |origin|
      @page.go_to("#{origin}/offline-probe")
      wait_until { @page.evaluate("typeof window.__offline === 'object'") }

      @page.network.offline_mode
      wait_until(5) { root_data("monkOffline") }
      assert_equal "network", root_data("monkOffline")
      refute @page.evaluate("document.querySelector('[data-monk-offline-banner]').hidden")
      assert_equal [false, true, true], visible_reason_hidden_flags
      assert_equal [{ "name" => "offline", "reason" => "network" }], offline_events

      @page.evaluate("document.querySelector('#away').click()")
      wait_until { root_data("monkOfflineNudge") }
      assert_equal "#{origin}/offline-probe", @page.current_url, "the click was cancelled"

      @page.network.emulate_network_conditions(offline: false)
      wait_until(5) { root_data("monkOffline").nil? }
      assert @page.evaluate("document.querySelector('[data-monk-offline-banner]').hidden")
      assert_equal "online", offline_events.last["name"]
    end
  end

  # A drop shorter than the delay shows nothing.
  def test_a_short_drop_shows_no_banner
    with_offline_probe do |origin|
      @page.go_to("#{origin}/offline-probe")
      wait_until { @page.evaluate("typeof window.__offline === 'object'") }

      @page.network.offline_mode
      sleep 0.5
      @page.network.emulate_network_conditions(offline: false)
      sleep 2.5

      assert_nil root_data("monkOffline")
      assert_empty offline_events
    end
  end

  # The proxy answering for an app that's down (/_monk/up gets a 503 here,
  # from Chrome's request interception): "server". Live coming back
  # probes at once, and the app answering clears it.
  def test_the_server_down_behind_its_proxy_reads_as_server_and_live_coming_back_clears_it
    with_offline_probe do |origin|
      @page.go_to("#{origin}/offline-probe")
      wait_until { @page.evaluate("typeof window.__offline === 'object'") }
      down = true
      @page.network.intercept(pattern: "*/_monk/up")
      @page.on(:request) { |request| down ? request.respond(responseCode: 503, body: "") : request.continue }

      @page.execute("document.dispatchEvent(new CustomEvent('monk-live:disconnected'))")
      wait_until(5) { root_data("monkOffline") }
      assert_equal "server", root_data("monkOffline")

      down = false
      @page.execute("document.dispatchEvent(new CustomEvent('monk-live:connected'))")
      wait_until(5) { root_data("monkOffline").nil? }
    end
  end

  # The app stopped: the app's check reads "unreachable"; a reload gets the
  # stored offline.html from the worker; the app back, that page reloads
  # itself into the page that couldn't load.
  def test_the_app_unreachable_then_a_reload_shows_the_offline_page_until_it_is_back
    with_offline_probe do |origin, restart, stop|
      @page.go_to("#{origin}/offline-probe")
      @page.evaluate_async("navigator.serviceWorker.ready.then(() => arguments[0](true))", 10)
      wait_until(10) do
        @page.evaluate_async("caches.open('monk-offline').then((c) => c.match('/offline.html'))" \
                             ".then((r) => arguments[0](!!r))", 5,)
      end
      @page.refresh # now controlled by the worker
      wait_until { @page.evaluate("navigator.serviceWorker.controller !== null") }

      stop.call
      @page.execute("document.dispatchEvent(new CustomEvent('monk-offline:check'))")
      wait_until(5) { root_data("monkOffline") }
      assert_equal "unreachable", root_data("monkOffline")

      @page.refresh
      wait_until(5) { @page.evaluate("document.title") == "shop: offline" }
      assert_equal "#{origin}/offline-probe", @page.current_url

      restart.call
      wait_until(15) { @page.evaluate("document.querySelector('#away') !== null") }
    end
  end

  # push.js in a generated push app (monk add push): the page learns its
  # state at once, even with notifications allowed and a push service that
  # never answers -- headless Chrome reaches none, so subscribing itself is
  # left to the device checks (docs/history/plan-pwa-push.md step 10).
  def test_push_js_reports_the_state_of_this_browser
    with_new_app(:push) do |dest|
      with_generated_database do |database|
        out, status = run_generated_script(dest, "bin/setup_db", database)
        assert status.success?, out

        with_server(dest, database.merge(test_env(dest))) do |port|
          origin = "http://127.0.0.1:#{port}"
          assert_equal "off", push_state(origin), "not asked yet"

          @page.command("Browser.grantPermissions", origin: origin, permissions: ["notifications"])
          assert_equal "off", push_state(origin), "allowed, re-subscribing, the push service silent"

          @page.command("Browser.setPermission", origin: origin, permission: { name: "notifications" },
            setting: "denied",)
          assert_equal "denied", push_state(origin)
        end
      end
    end
  end

  private

  # A pwa app with a page carrying auth's meta, and a stand-in /auth/own
  # that records the CSRF header of each call in tmp/own_calls, answering
  # tmp/own_status's status (200 without it).
  def with_own_session_probe
    with_new_app(:pwa) do |dest|
      FileUtils.mkdir_p(File.join(dest, "tmp"))
      File.write(File.join(dest, "app/views/own_probe.erb"),
        %(<meta name="monk-auth-own-url" content="/auth/own"><p>probe</p>\n),)
      File.write(File.join(dest, "app/routes/own_probe.rb"), <<~RUBY)
        class App
          OWN_PROBE_DIR = File.expand_path("../../tmp", __dir__).freeze

          get("/own-probe") { render "own_probe" }
          post("/auth/own") do
            File.write(File.join(OWN_PROBE_DIR, "own_calls"), "\#{header("x-csrf-token")}\\n", mode: "a")
            status_file = File.join(OWN_PROBE_DIR, "own_status")
            halt(Integer(File.read(status_file))) if File.exist?(status_file)
            json(ok: true)
          end
        end
      RUBY
      log = File.join(dest, "tmp/own_calls")
      calls = -> { File.exist?(log) ? File.read(log).lines(chomp: true) : [] }
      with_server(dest) { |port| yield "http://127.0.0.1:#{port}", calls, dest }
    end
  end

  # A pwa app with a page holding <%= monk_install %>. Chrome's own install
  # events (it may offer, or think the app installed, from an earlier test
  # in this profile) are kept from the page: only the test's own reach it.
  def with_install_probe
    @page.command("Page.addScriptToEvaluateOnNewDocument", source: <<~JS)
      for (const name of ["beforeinstallprompt", "appinstalled"]) {
        addEventListener(name, (event) => { if (event.isTrusted) event.stopImmediatePropagation(); }, true);
      }
    JS
    with_new_app(:pwa) do |dest|
      File.write(File.join(dest, "app/views/install_probe.erb"), "<%= monk_install %>\n")
      File.write(File.join(dest, "app/routes/install_probe.rb"), <<~RUBY)
        class App
          get("/install-probe") { render "install_probe" }
        end
      RUBY
      with_server(dest) { |port| yield "http://127.0.0.1:#{port}" }
    end
  end

  # A pwa app with a page holding <%= monk_offline %> and two links, its
  # monk-offline events recorded on window.__offline. Yields the origin,
  # and lambdas that start the app again on the same port, and stop it.
  def with_offline_probe
    @page.command("Page.addScriptToEvaluateOnNewDocument", source: <<~JS)
      window.__offline = [];
      for (const name of ["offline", "online"]) {
        document.addEventListener("monk-offline:" + name, (e) => window.__offline.push({ name, ...e.detail }));
      }
    JS
    with_new_app(:pwa) do |dest|
      File.write(File.join(dest, "app/views/offline_probe.erb"),
        %(<%= monk_offline %>\n<a id="away" href="/hello">away</a> <a id="here" href="#x">here</a>\n),)
      File.write(File.join(dest, "app/routes/offline_probe.rb"), <<~RUBY)
        class App
          get("/offline-probe") { render "offline_probe" }
        end
      RUBY
      port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
      pid = start_server(dest, port)
      stop = lambda {
        Process.kill("TERM", pid)
        Process.wait(pid)
        pid = nil
      }
      restart = -> { pid = start_server(dest, port) }
      begin
        yield "http://127.0.0.1:#{port}", restart, stop
      ensure
        stop.call if pid
      end
    end
  end

  def start_server(dest, port)
    env = { "PORT" => port.to_s, "MONK_ENV" => "test", "BUNDLE_GEMFILE" => File.expand_path("../Gemfile", __dir__) }
    pid = Process.spawn(env, "bin/server", chdir: dest, out: File::NULL, err: File::NULL)
    wait_for_port(port, pid)
    pid
  end

  def offline_events = @page.evaluate("window.__offline")

  # The banner's texts, in order (network, server, unreachable): hidden or not.
  def visible_reason_hidden_flags
    @page.evaluate("[...document.querySelectorAll('[data-monk-offline-reason]')].map((p) => p.hidden)")
  end

  def user_agent(value) = @page.command("Emulation.setUserAgentOverride", userAgent: value)

  def root_data(name) = @page.evaluate("document.documentElement.dataset.#{name} ?? null")

  def pretend_standalone
    @page.command("Page.addScriptToEvaluateOnNewDocument",
      source: "Object.defineProperty(Navigator.prototype, 'standalone', { get: () => true })",)
  end

  # Long enough for register.js's fetch, had it made one.
  def settle
    @page.evaluate_async("navigator.serviceWorker.ready.then(() => setTimeout(() => arguments[0](true), 500))", 10)
  end

  def wait_until(timeout = 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  def push_state(origin)
    @page.go_to("#{origin}/")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      state = @page.evaluate("document.documentElement.dataset.pushState")
      return state if state

      flunk "push.js set no data-push-state" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  # .env.test's values, as the app's own tests load them; the database's
  # come from with_generated_database.
  def test_env(dest)
    File.read(File.join(dest, ".env.test")).lines.filter_map do |line|
      key, value = line.chomp.split("=", 2)
      [key, value.delete_prefix('"').delete_suffix('"')] if value && !key.start_with?("DB_", "#")
    end.to_h
  end

  # DevTools names registrations in workerRegistrationUpdated events,
  # sent for each existing one once ServiceWorker is enabled.
  def wait_for_registration_id(origin)
    found = Queue.new
    @page.on("ServiceWorker.workerRegistrationUpdated") do |params|
      params["registrations"].each do |registration|
        found << registration["registrationId"] if registration["scopeURL"].start_with?(origin)
      end
    end
    @page.command("ServiceWorker.enable")
    found.pop(timeout: 10) || flunk("DevTools reported no registration for #{origin}")
  end

  def wait_for_notifications
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      shown = @page.evaluate_async(<<~JS, 10)
        navigator.serviceWorker.ready.then((r) => r.getNotifications())
          .then((list) => arguments[0](list.map((n) => [n.title, n.body, n.tag, n.data.url])))
      JS
      return shown.tap { close_notifications } unless shown.empty?

      flunk "no notification shown" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
  end

  # What a test showed is closed again, in case Chrome still handed it to
  # the system despite browser_options above.
  def close_notifications
    @page.evaluate_async(<<~JS, 10)
      navigator.serviceWorker.ready.then((r) => r.getNotifications())
        .then((list) => list.forEach((n) => n.close())).then(() => arguments[0](true))
    JS
  end

  def default_profile_page(browser)
    id = browser.command("Target.getTargets")["targetInfos"].find { |info| info["type"] == "page" }["browserContextId"]
    contexts = browser.contexts.instance_variable_get(:@contexts)
    context = contexts[id] ||= Ferrum::Context.new(browser.client, browser.contexts, id)
    context.create_page
  end

  def with_server(dest, app_env = {})
    port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
    env = app_env.merge("PORT" => port.to_s, "MONK_ENV" => "test",
      "BUNDLE_GEMFILE" => File.expand_path("../Gemfile", __dir__),)
    pid = Process.spawn(env, "bin/server", chdir: dest, out: File::NULL, err: File::NULL)
    wait_for_port(port, pid)
    yield port
  ensure
    if pid
      Process.kill("TERM", pid)
      Process.wait(pid)
    end
  end

  def wait_for_port(port, pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    loop do
      flunk "bin/server exited at boot" if Process.wait(pid, Process::WNOHANG)
      return TCPSocket.new("127.0.0.1", port).close
    rescue Errno::ECONNREFUSED
      flunk "bin/server didn't listen within 20s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end
end
