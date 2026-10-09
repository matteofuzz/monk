require_relative "../test_helper"
require "pg"

# Every `# monk:example` block, uncommented in a generated app, works:
# docs/history/plan-scaffold.md decision 15. The app's own suite runs with a probe
# test per example, so an API change that breaks an example breaks this
# test instead of the first app that copies it.
class GeneratorsExamplesTest < Minitest::Test
  include GeneratorTestHelpers
  include PersistenceTestHelpers
  include RedisTestHelpers

  # The apps whose examples are checked, together every module. Two apps,
  # because with live bin/websocket_server runs live's handler, never the
  # chat example's -- and that way each transport is used by one.
  SUITES = {
    without_live: [%i[postgres redis mail auth jobs websocket], { transport: "redis" }],
    with_live: [%i[live], { transport: "postgres" }],
  }.freeze

  # What each example does once uncommented, as test methods in the app.
  # `request` (defined below, in PROBE_HELPERS) goes through the booted APP.
  PROBES = {
    "postgres-model" => <<~RUBY,
      def test_postgres_model
        Monk::Persistence::Pg.checkout(:primary) do |conn|
          conn.exec("CREATE TABLE notes (id BIGSERIAL PRIMARY KEY, body TEXT NOT NULL)")
        end

        assert_equal 200, request("POST", "/notes", body: "hello").first
        status, body = request("GET", "/notes")

        assert_equal 200, status
        assert_equal ["hello"], JSON.parse(body)["notes"].map { |note| note["body"] }
      end
    RUBY
    "redis-cache" => <<~RUBY,
      def test_redis_cache
        Redis.new(url: Monk::Settings[:redis_url]).then { |redis| redis.del("cached:now") && redis.close }

        first = JSON.parse(request("GET", "/cached/now")[1])["now"]
        second = JSON.parse(request("GET", "/cached/now")[1])["now"]

        refute_nil first
        assert_equal first, second, "the second request reads the cached value"
      end
    RUBY
    "mail-welcome" => <<~RUBY,
      def test_mail_welcome
        assert_equal 200, request("POST", "/welcome", email: "ann@example.test", name: "Ann").first

        assert_includes File.read(File.expand_path("../log/test.log", __dir__)), %(subject="Welcome, Ann")
      end
    RUBY
    "auth-routes" => <<~RUBY,
      def test_auth_routes
        status, body = request("GET", "/login")
        assert_equal 200, status
        assert_includes body, %(id="login")

        email = "probe-\#{rand(1_000_000)}@example.test"
        assert_equal 200, request("POST", "/auth/request", email: email).first
        token = File.read(File.expand_path("../log/test.log", __dir__)).scan(%r{/auth/callback/([\\w-]+)}).last.first

        status, _body, headers = request("GET", "/auth/callback/\#{token}")
        assert_equal 302, status
        cookies = Array(headers["set-cookie"]).to_h { |cookie| cookie.split(";").first.split("=", 2) }
        logged_in = { "HTTP_COOKIE" => cookies.map { |name, value| "\#{name}=\#{value}" }.join("; ") }
        assert_equal [200, %({"email":"\#{email}"})], request("GET", "/me", nil, logged_in).first(2)

        csrf = logged_in.merge("HTTP_X_CSRF_TOKEN" => cookies["csrf_token"])
        assert_equal 200, request("POST", "/auth/logout", nil, csrf).first
        assert_equal 401, request("GET", "/me", nil, logged_in).first

        statuses = Array.new(6) { request("POST", "/auth/request", email: email).first }
        assert_includes statuses, 429, "the rate limit stops a flood of links"
      end
    RUBY
    "jobs-enqueue" => <<~RUBY,
      def test_jobs_enqueue
        status, body = request("POST", "/jobs/hello?name=Ann")

        assert_equal 200, status
        refute_nil JSON.parse(body)["enqueued"]
        assert_equal 1, Monk::Jobs.drain!
        assert_includes File.read(File.expand_path("../log/test.log", __dir__)), "Hello, Ann, from a background job"
      ensure
        Monk::Jobs.clear!
      end
    RUBY
    "websocket-chat" => <<~RUBY,
      def test_websocket_chat
        skip "with live, bin/websocket_server runs live's handler" if File.exist?(File.expand_path("../config/live.rb", __dir__))

        # With auth the server refuses an anonymous socket: log in first.
        speaker, cookie = "guest", nil
        if defined?(Monk::Auth) && Monk::Auth.config
          speaker = "chat@example.test"
          cookie = "session_token=\#{Monk::Auth.redeem(Monk::Auth.request_login(speaker))[:token]}"
        end
        port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
        pid = Process.spawn({ "WS_PORT" => port.to_s }, RbConfig.ruby, "-W0", "bin/websocket_server",
          chdir: File.expand_path("..", __dir__), out: File::NULL, err: File::NULL)
        socket = ws_connect(port, cookie: cookie)

        ws_send(socket, "hi")

        assert_equal "\#{speaker}: hi", ws_read(socket)
      ensure
        socket&.close
        Process.kill("TERM", pid) && Process.wait(pid) if pid
      end
    RUBY
    "live-rule" => <<~RUBY,
      def test_live_rule
        assert Monk::Live.authorized?("7", "contacts:7")
        refute Monk::Live.authorized?("7", "contacts:8")
        refute Monk::Live.authorized?(nil, "contacts:")
      end
    RUBY
    "live-broadcast" => <<~RUBY,
      def test_live_broadcast
        AppWebSocket::REGISTRY.listen!
        port = Ractor::Port.new
        AppWebSocket::REGISTRY.register(:greeting, port)

        assert_equal 200, request("POST", "/greeting", text: "Hi all").first

        envelope = JSON.parse(Timeout.timeout(5) { port.receive })
        assert_equal %(<span id="greeting">Hi all</span>\\n), envelope["html"]
      ensure
        AppWebSocket::REGISTRY.unregister(:greeting, port) if port
        port&.close
      end
    RUBY
  }.freeze

  PROBE_HELPERS = <<~'RUBY'.freeze
    require "json"
    require "rack"
    require "socket"
    require "timeout"

    # A WebSocket client, just enough to talk to bin/websocket_server.
    def ws_connect(port, cookie: nil, deadline: Time.now + 20)
      socket = begin
        TCPSocket.new("127.0.0.1", port)
      rescue Errno::ECONNREFUSED
        raise if Time.now > deadline

        sleep 0.1
        retry
      end
      socket.write("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n" \
        "Origin: http://localhost:9292\r\n#{"Cookie: #{cookie}\r\n" if cookie}\r\n")
      response = +""
      response << socket.readpartial(1024) until response.include?("\r\n\r\n")
      raise "no WebSocket upgrade: #{response.lines.first}" unless response.start_with?("HTTP/1.1 101")

      socket
    end

    # A client's text frame is masked (RFC 6455); a short one is enough here.
    def ws_send(socket, text)
      mask = Random.bytes(4)
      payload = text.b.bytes.each_with_index.map { |byte, index| byte ^ mask.getbyte(index % 4) }.pack("C*")
      socket.write([0x81, 0x80 | payload.bytesize].pack("CC") + mask + payload)
    end

    def ws_read(socket)
      _opcode, length = socket.read(2).bytes
      socket.read(length & 0x7f)
    end

    # Monk reads params from the query string and JSON bodies. Returns
    # [status, body, headers].
    def request(method, path, json = nil, env = {})
      options = { method: method }
      options.merge!(input: JSON.generate(json), "CONTENT_TYPE" => "application/json") if json
      status, headers, body = APP.call(Rack::MockRequest.env_for(path, **options).merge(env))
      [status, body.join, headers]
    end
  RUBY

  def test_every_example_has_a_probe
    tags = SUITES.values.flat_map do |modules, options|
      with_new_app(*modules, options: options) { |dest| example_tags(dest) }
    end

    assert_equal PROBES.keys.sort, tags.uniq.sort
  end

  SUITES.each do |name, (modules, options)|
    define_method(:"test_every_example_works_uncommented_#{name}") do
      run_examples(modules, options)
    end
  end

  private

  def run_examples(modules, options)
    skip_unless_redis_available

    with_new_app(*modules, options: options) do |dest|
      uncomment_examples(dest)
      write_probes(dest)

      with_generated_database do |database|
        env = database.merge("REDIS_URL" => redis_test_url)
        out, status = run_generated_script(dest, "bin/setup_db", env)
        assert status.success?, out

        assert_generated_tests_pass(dest, env)
      end
    end
  end

  def write_probes(dest)
    body = [PROBE_HELPERS, *example_tags(dest).map { |tag| PROBES.fetch(tag) }].join("\n")
    File.write(File.join(dest, "test/examples_probe_test.rb"), <<~RUBY)
      require_relative "test_helper"

      class ExamplesProbeTest < Minitest::Test
      #{body.gsub(/^(?=.)/, "  ")}
      end
    RUBY
  end
end
