$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
ENV["MONK_ENV"] ||= "test"

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "fileutils"
require "monk"

module EnvHelper
  def env_for(method, path)
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "rack.input" => StringIO.new(""),
    }
  end
end

Minitest::Test.include(EnvHelper)

# Shared by views_test.rb and assets_test.rb: a throwaway views/ or
# public/ root on disk, torn down after the block, with the global
# Monk::Views / Monk::Assets state reset either way.
module ViewTestHelpers
  def with_views(templates)
    with_tree("monk-views", templates) do |dir|
      Monk::Views.reset!
      Monk::Views.root = dir
      begin
        yield dir
      ensure
        Monk::Views.reset!
      end
    end
  end

  def with_assets(files)
    with_tree("monk-assets", files) do |dir|
      Monk::Assets.reset!
      Monk::Assets.root = dir
      begin
        yield dir
      ensure
        Monk::Assets.reset!
      end
    end
  end

  def with_log
    with_tree("monk-log", {}) do |dir|
      Monk::Log.reset!
      Monk::Log.root = dir
      begin
        yield dir
      ensure
        Monk::Log.reset!
      end
    end
  end

  # Monk reads MONK_ENV once, at boot, never per request -- so a test
  # that wants development behavior has to set it before .freeze!.
  def with_monk_env(value)
    with_env("MONK_ENV", value) { yield }
  end

  # Sets (or, given nil, clears) an arbitrary ENV var for the duration of
  # the block, restoring whatever was there before either way.
  def with_env(name, value)
    previous = ENV[name]
    ENV[name] = value
    yield
  ensure
    ENV[name] = previous
  end

  # Monk::Settings is global, module-level state, same as Monk::Assets/
  # Monk::Views -- reset on both sides of the block so one test's
  # declared keys never leak into another's.
  def with_settings
    Monk::Settings.reset!
    yield
  ensure
    Monk::Settings.reset!
  end

  def write_file(dir, relative, content)
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  private

  def with_tree(prefix, files)
    Dir.mktmpdir(prefix) do |dir|
      files.each { |relative, content| write_file(dir, relative, content) }
      yield dir
    end
  end
end

Minitest::Test.include(ViewTestHelpers)

# Shared by tests that need a real Postgres connection (persistence_*_test.rb).
# Not included globally -- `include PersistenceTestHelpers` where needed.
module PersistenceTestHelpers
  def pg_test_opts
    {
      host: ENV.fetch("MONK_TEST_PG_HOST", "127.0.0.1"),
      port: ENV.fetch("MONK_TEST_PG_PORT", "5432").to_i,
      user: ENV.fetch("MONK_TEST_PG_USER", "postgres"),
      password: ENV.fetch("MONK_TEST_PG_PASSWORD", "postgres"),
      dbname: ENV.fetch("MONK_TEST_PG_DATABASE", "monk_test"),
    }
  end

  def postgres_available?
    return @postgres_available if defined?(@postgres_available)

    PG.connect(**pg_test_opts).finish
    @postgres_available = true
  rescue PG::Error
    @postgres_available = false
  end

  def skip_unless_postgres_available
    skip "no local Postgres reachable at #{pg_test_opts[:host]}:#{pg_test_opts[:port]} " \
      "(set MONK_TEST_PG_* env vars, or start one -- see docs/persistence-ractor-connections.md)" unless postgres_available?
  end
end

# Shared by the raw-socket websocket tests (websocket_server_test.rb,
# websocket_close_test.rb, websocket_ping_pong_test.rb,
# websocket_registry_lifecycle_test.rb, websocket_ractor_integration_test.rb,
# websocket_auth_test.rb) -- a minimal client that speaks the handshake and
# frame wire format itself, deliberately independent of
# Monk::WebSocket::Connection where a test needs to see something
# Connection#read hides (close/ping/pong control frames).
module WebSocketTestHelpers
  CLIENT_KEY = "dGhlIHNhbXBsZSBub25jZQ=="

  def teardown
    @server_thread&.kill
    @server_thread&.join
  end

  def start_server(**kwargs, &block)
    server = Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1", **kwargs)
    @server_thread = Thread.new { server.run(&block) }
    server
  end

  def handshake!(socket, extra_headers: {})
    request = +"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
      "Sec-WebSocket-Key: #{CLIENT_KEY}\r\nSec-WebSocket-Version: 13\r\n"
    extra_headers.each { |k, v| request << "#{k}: #{v}\r\n" }
    request << "\r\n"
    socket.write(request)

    response = +""
    until response.end_with?("\r\n\r\n")
      byte = socket.read(1)
      return nil if byte.nil?

      response << byte
    end
    response
  end

  # Uses Connection#read directly as the test client's own frame parser --
  # hides control frames (ping/pong/close) the way real app code would.
  # Use #read_raw_frame instead when a test needs to see the opcode itself.
  def read_frame(socket)
    Monk::WebSocket::Connection.new(socket).read
  end

  # Deliberately independent of Connection#read -- reads whatever frame type
  # the server actually sent, opcode included, for tests that need to see
  # control frames Connection#read would otherwise hide.
  def read_raw_frame(socket)
    header = socket.read(2)
    return nil unless header

    byte1 = header.getbyte(1)
    length_indicator = byte1 & 0x7F
    extended =
      case length_indicator
      when 126 then socket.read(2)
      when 127 then socket.read(8)
      else ""
      end
    length = case length_indicator
             when 126 then extended.unpack1("n")
             when 127 then extended.unpack1("Q>")
             else length_indicator
             end
    payload = length.zero? ? "" : socket.read(length)

    Monk::WebSocket::Frame.decode(header + extended.to_s + payload.to_s)
  end

  def wait_until(timeout: 1.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end
end

# Shared by tests that need real login_tokens/sessions tables and a
# configured Monk::Auth (auth_test.rb, auth_helpers_test.rb). Include
# PersistenceTestHelpers alongside this -- it's built on top of it.
module AuthTestHelpers
  def setup_auth_tables(db_name)
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(db_name, **pg_test_opts)
    Monk::Persistence::Pg.checkout(db_name) do |conn|
      drop_auth_tables(conn)
      conn.exec(<<~SQL)
        CREATE TABLE login_tokens (
          id BIGSERIAL PRIMARY KEY,
          email TEXT NOT NULL,
          token_hash TEXT NOT NULL UNIQUE,
          redirect_to TEXT,
          expires_at TIMESTAMPTZ NOT NULL,
          used_at TIMESTAMPTZ,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
      SQL
      conn.exec(<<~SQL)
        CREATE TABLE sessions (
          id BIGSERIAL PRIMARY KEY,
          subject TEXT NOT NULL,
          token_hash TEXT NOT NULL UNIQUE,
          expires_at TIMESTAMPTZ NOT NULL,
          revoked_at TIMESTAMPTZ,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
      SQL
    end
    Monk::Auth.configure(
      db_name: db_name, secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600,
      redirect_allowlist: ["/dashboard"],
    )
  end

  def drop_auth_tables(conn)
    conn.exec("DROP TABLE IF EXISTS sessions")
    conn.exec("DROP TABLE IF EXISTS login_tokens")
  end
end
