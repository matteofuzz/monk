require_relative "test_helper"
require "socket"

# A generated app with pwa (monk new shop --with pwa), served by its own
# bin/server, in real headless Chrome: Chrome registers /sw.js for the
# whole site and finds nothing stopping it installing the app, from the
# files exactly as monk add writes them (docs/plan-pwa-push.md, A4).
class PwaBrowserTest < Minitest::Test
  include GeneratorTestHelpers

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
        Ferrum::Browser.new(headless: :new, timeout: 20, process_timeout: 30, incognito: false).tap do |browser|
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

  private

  def default_profile_page(browser)
    id = browser.command("Target.getTargets")["targetInfos"].find { |info| info["type"] == "page" }["browserContextId"]
    contexts = browser.contexts.instance_variable_get(:@contexts)
    context = contexts[id] ||= Ferrum::Context.new(browser.client, browser.contexts, id)
    context.create_page
  end

  def with_server(dest)
    port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
    env = { "PORT" => port.to_s, "MONK_ENV" => "test", "BUNDLE_GEMFILE" => File.expand_path("../Gemfile", __dir__) }
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
