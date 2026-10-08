require_relative "../test_helper"
require "socket"
require "securerandom"
require "pg"
require "monk/auth"

# The generated bin/websocket_server, as a real process: with auth it
# starts config/auth.rb's :auth pool and checks sessions through it, so its
# Postgres connections stay fixed however many sockets are open. Every
# connection the process opens carries PGAPPNAME's name.
class GeneratorsWebSocketServerTest < Minitest::Test
  include GeneratorTestHelpers
  include PersistenceTestHelpers
  include AuthTestHelpers
  include RedisTestHelpers
  include WebSocketTestHelpers

  POOL_SIZE = 4

  def setup
    Monk::Persistence::Pg.reset!
    Monk::Auth.reset!
  end

  def teardown
    super
    Monk::Persistence::Pg.checkout(:primary) { |conn| drop_auth_tables(conn) } if postgres_available?
  rescue Monk::UnknownPersistenceError
    nil
  ensure
    Monk::Persistence::Pg.reset!
    Monk::Auth.reset!
  end

  # The chat example over Redis: the pool is all the Postgres it holds.
  def test_the_app_sockets_server_checks_sessions_through_the_pool
    assert_connections_stay_fixed(:auth, :websocket, transport: "redis", extra: 0)
  end

  # Live over Postgres: PgFanout's LISTEN is one more connection.
  def test_the_live_server_checks_sessions_through_the_pool
    assert_connections_stay_fixed(:auth, :live, transport: "postgres", extra: 1)
  end

  # Without auth, no pool and no Postgres: a socket is let in anonymously.
  def test_without_auth_the_server_boots_without_a_pool
    skip_unless_redis_available

    with_new_app(:websocket, options: { transport: "redis" }) do |dest|
      uncomment_examples(dest)
      with_server(dest, "unused") do |port|
        socket = TCPSocket.new("127.0.0.1", port)

        assert_equal "HTTP/1.1 101 Switching Protocols", handshake!(socket).lines.first.strip
      ensure
        socket&.close
      end
    end
  end

  private

  def assert_connections_stay_fixed(*modules, transport:, extra:)
    skip_unless_redis_available
    setup_auth_tables(:primary)
    token = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))[:token]

    with_new_app(*modules, options: { transport: transport }) do |dest|
      uncomment_examples(dest) # the chat handler, for an app without live
      app_name = "monk_generated_ws_#{SecureRandom.hex(4)}"
      with_server(dest, app_name) do |port|
        assert_equal POOL_SIZE + extra, backend_count(app_name), "at boot: the pool's connections"

        sockets = Array.new(10) do
          TCPSocket.new("127.0.0.1", port).tap do |socket|
            response = handshake!(socket, extra_headers: { "Authorization" => "Bearer #{token}" })
            assert_equal "HTTP/1.1 101 Switching Protocols", response.lines.first.strip
          end
        end

        assert_equal POOL_SIZE + extra, backend_count(app_name), "10 open sockets add none"
      ensure
        sockets&.each(&:close)
      end
    end
  end

  def with_server(dest, app_name)
    port = free_port
    pid = Process.spawn(server_env(port, app_name), RbConfig.ruby, "-W0", "bin/websocket_server",
      chdir: dest, out: File::NULL,)
    wait_for_port(port, pid)
    yield port
  ensure
    stop(pid) if pid
  end

  # What the generated configs read, pointed at the test database
  # (AUTH_SECRET: setup_auth_tables's) and the test Redis.
  def server_env(port, app_name)
    opts = pg_test_opts
    {
      "DB_HOST" => opts[:host], "DB_PORT" => opts[:port].to_s, "DB_USER" => opts[:user],
      "DB_PASSWORD" => opts[:password], "DB_NAME" => opts[:dbname], "REDIS_URL" => redis_test_url,
      "MONK_ENV" => "test", "AUTH_SECRET" => "s3cr3t", "WS_PORT" => port.to_s, "PGAPPNAME" => app_name,
      "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__),
    }
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def wait_for_port(port, pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    loop do
      flunk "bin/websocket_server exited at boot" if Process.wait(pid, Process::WNOHANG)
      return TCPSocket.new("127.0.0.1", port).close
    rescue Errno::ECONNREFUSED
      late = Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      flunk "bin/websocket_server didn't listen within 15s" if late
      sleep 0.05
    end
  end

  def stop(pid)
    Process.kill("TERM", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def backend_count(app_name)
    Monk::Persistence::Pg.checkout(:primary) do |conn|
      sql = "SELECT count(*) FROM pg_stat_activity WHERE application_name = $1"
      conn.exec_params(sql, [app_name]).getvalue(0, 0).to_i
    end
  end
end
