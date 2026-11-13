require "socket"
require "timeout"
require "monk/websocket"
require "monk/live"

# Real-browser tests for the Monk::Live client (lib/monk/live/client): a
# headless Chrome driven by Ferrum, a real Monk::WebSocket::Server running
# Monk::Live::HANDLER, and a tiny HTTP server for the page and the client
# files. They skip when Ferrum or Chrome aren't available, the same way the
# Postgres and Redis tests skip.
module LiveBrowserPage
  EVENTS = %w[connected disconnected stale subscribed patched gap resynced resync-failed stopped].freeze

  # Serves `body_html` as the app page (with the client wired in and every
  # monk-live event recorded on window.__events) and opens it.
  def open_page(body_html, topics_ready: nil)
    @pages.serve_page(page_html(body_html))
    @page.go_to("http://127.0.0.1:#{@pages.port}/page")
    return unless topics_ready != false

    wait_for("client subscribed") do
      evaluate("window.__events.some(e => e.name === 'subscribed')")
    end
  end

  def page_html(body_html)
    <<~HTML
      <!doctype html><meta charset="utf-8">
      <link rel="icon" href="data:,">
      <meta name="monk-live-url" content="ws://127.0.0.1:#{@proxy.port}">
      <script>
        window.__events = [];
        // Every socket the client opens, even one the browser blocks, and
        // every message it sends, in order.
        window.__sockets = 0;
        window.__sent = [];
        window.WebSocket = class extends window.WebSocket {
          constructor(...args) { super(...args); window.__sockets += 1; }
          send(data) { window.__sent.push(data); super.send(data); }
        };
        #{EVENTS.to_json}.forEach(n => document.addEventListener("monk-live:" + n,
          e => window.__events.push({ name: n, detail: e.detail, at: performance.now() })));
      </script>
      <body>#{body_html}<script type="module" src="/js/monk_live.js"></script></body>
    HTML
  end

  # Ferrum wraps this in `return <js>`, so anything after a first `;`
  # never runs: wrap multi-statement scripts in an IIFE.
  def evaluate(script)
    @page.evaluate(script)
  end

  # Runs a multi-statement body (use `return` for a result) as an IIFE.
  def run_js(body)
    evaluate("(() => { #{body} })()")
  end

  def events(name)
    evaluate("window.__events.filter(e => e.name === #{name.to_json}).map(e => e.detail)")
  end

  def wait_for(what, timeout: 6)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until (result = yield)
      raise "timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
    result
  end
end

module LiveBrowserHelpers
  include LiveBrowserPage

  CLIENT_DIR = File.expand_path("../lib/monk/live/client", __dir__)

  # One Chrome for the whole run: starting it costs about a second.
  def self.browser
    return @browser if defined?(@browser)

    @browser =
      begin
        require "ferrum"
        Ferrum::Browser.new(headless: :new, timeout: 20, process_timeout: 30).tap do |browser|
          at_exit { browser.quit }
        end
      rescue LoadError, StandardError
        nil
      end
  end

  # Serves the page under test (whatever #serve_page last set) and the
  # client files, one request per connection.
  class PageServer
    attr_reader :port, :page_hits
    # Replacements made in a client file as it's served, e.g. shorter
    # heartbeat constants: { "protocol.js" => { "from" => "to" } }.
    attr_accessor :js_overrides
    # Sent with every response; nil sends none, as Monk doesn't on HTML,
    # which lets Chrome keep the page in its back/forward cache.
    attr_accessor :cache_control

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @page = [200, {}, "", 0, false]
      @page_hits = 0
      @js_overrides = {}
      @cache_control = "no-store"
      @thread = Thread.new { loop { handle(@server.accept) } }
    end

    # `delay:` holds the response back (seconds); `drop: true` closes the
    # connection without answering, which the browser sees as a network error.
    def serve_page(body, status: 200, headers: {}, delay: 0, drop: false)
      @page = [status, headers, body, delay, drop]
    end

    def close
      @thread.kill
      @server.close
    end

    private

    def handle(client)
      Thread.new do
        path = client.gets.to_s.split[1].to_s
        while (line = client.gets) && line != "\r\n"; end
        respond(client, path)
      rescue IOError, SystemCallError
        nil
      ensure
        client.close
      end
    end

    def respond(client, path)
      case path
      when %r{\A/js/([\w.]+\.js)\z}
        file = File.join(CLIENT_DIR, Regexp.last_match(1))
        return write(client, 404, {}, "") unless File.file?(file)

        source = (@js_overrides[Regexp.last_match(1)] || {}).reduce(File.read(file)) do |text, (from, to)|
          text.include?(from) ? text.sub(from, to) : raise("#{from.inspect} not in #{file}")
        end
        write(client, 200, { "content-type" => "text/javascript" }, source)
      when "/login"
        write(client, 200, { "content-type" => "text/html" }, "<body>login</body>")
      else
        status, headers, body, delay, drop = @page
        @page_hits += 1
        sleep delay if delay.positive?
        return if drop

        write(client, status, { "content-type" => "text/html; charset=utf-8" }.merge(headers), body)
      end
    end

    def write(client, status, headers, body)
      head = headers.merge("content-length" => body.bytesize.to_s, "connection" => "close")
      head["cache-control"] = @cache_control if @cache_control
      client.write("HTTP/1.1 #{status} X\r\n#{head.map { |k, v| "#{k}: #{v}" }.join("\r\n")}\r\n\r\n#{body}")
    end
  end

  # A TCP proxy between the browser and the WS server, so a test can cut
  # the connection (a network drop), lose one server frame (a gap), or
  # go silent without closing anything (a phone that changed network).
  class WsProxy
    attr_reader :port, :connections, :upstream_bytes

    def initialize(target_port)
      @target_port = target_port
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @pairs = []
      @drop_next = false
      @connections = 0
      @upstream_bytes = 0
      @thread = Thread.new { loop { accept(@server.accept) } }
    end

    def sever!
      @pairs.each { |pair| pair.each { |socket| socket.close unless socket.closed? } }
      @pairs.clear
    end

    # Everything already open stops getting through, both ways, and
    # nothing is closed: neither end hears a FIN or an RST, as when a
    # phone's network goes away under it. Both ends' own TCP stays happy
    # (loopback acks everything), so this is the worst case: only a
    # timeout of the client's or the server's own can notice. New
    # connections get through, as a phone's would on its new network.
    def blackhole!
      @blackholed = @pairs.flatten
      @pairs.clear
    end

    # The blackholed connections finally close, as a dead socket's close
    # can reach the browser long after the client gave up on it.
    def release_blackholed!
      @blackholed&.each { |socket| socket.close unless socket.closed? }
    end

    def drop_next_server_frame!
      @drop_next = true
    end

    def close
      @thread.kill
      sever!
      @blackholed&.each { |socket| socket.close unless socket.closed? }
      @server.close
    end

    private

    def accept(client)
      upstream = TCPSocket.new("127.0.0.1", @target_port)
      @connections += 1
      @pairs << [client, upstream]
      Thread.new { pump_upstream(client, upstream) }
      Thread.new { pump_downstream(upstream, client) }
    end

    def blackholed?(socket) = @blackholed&.include?(socket)

    def pump_upstream(from, to)
      loop do
        data = from.readpartial(16_384)
        next if blackholed?(from)

        @upstream_bytes += data.bytesize
        to.write(data)
      end
    rescue IOError, SystemCallError
      nil
    ensure
      close_pair(from, to)
    end

    # Server -> client: forward the HTTP 101, then walk the (unmasked)
    # frames so one can be dropped whole.
    def pump_downstream(from, to)
      headers = +""
      headers << from.readpartial(1) until headers.end_with?("\r\n\r\n")
      to.write(headers)
      loop do
        head = from.read(2) or break
        length = head.getbyte(1) & 0x7F
        extended = length == 126 ? from.read(2) : ""
        length = extended.unpack1("n") if length == 126
        payload = from.read(length)
        next if blackholed?(from)

        if @drop_next && payload.start_with?('{"seq"')
          @drop_next = false
        else
          to.write(head + extended + payload)
        end
      end
    rescue IOError, SystemCallError
      nil
    ensure
      close_pair(from, to)
    end

    # Either side going away ends the whole connection, as a real network
    # (or a killed server) would.
    def close_pair(*sockets)
      sockets.each { |socket| socket.close unless socket.closed? }
    end
  end

  def setup
    skip "Ferrum/Chrome not available" unless LiveBrowserHelpers.browser

    @registry = Monk::WebSocket::Registry.new
    @publisher = Monk::Live::Publisher.new(@registry)
    Monk::Live.configure(registry: @registry)
    Monk::Live.authorize("t:*", anonymous: true, &self.class::ALLOW)
    @ws_server = Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1", **ws_server_options)
    @ws_thread = Thread.new { @ws_server.run(&ws_handler) }
    @proxy = WsProxy.new(@ws_server.port)
    @pages = PageServer.new
    @page = LiveBrowserHelpers.browser.create_page
  end

  def teardown
    @page&.close
    @pages&.close
    @proxy&.close
    @ws_thread&.kill
    Monk::Live.reset!
  end

  # What a test class may change about the WS server it runs.
  def ws_server_options = {}
  def ws_handler = Monk::Live::HANDLER
end
