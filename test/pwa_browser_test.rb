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

  # With the worker in control, requests still reach the app: it has no
  # fetch handler to get between Live's resync and the network.
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

  def pretend_standalone
    @page.command("Page.addScriptToEvaluateOnNewDocument",
      source: "Object.defineProperty(Navigator.prototype, 'standalone', { get: () => true })",)
  end

  # Long enough for register.js's fetch, had it made one.
  def settle
    @page.evaluate_async("navigator.serviceWorker.ready.then(() => setTimeout(() => arguments[0](true), 500))", 10)
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
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
