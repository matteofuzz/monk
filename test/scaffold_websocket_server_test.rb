require_relative "test_helper"
require "rbconfig"
require "tmpdir"
require "socket"
require "securerandom"
require "monk/scaffold"
require "monk/auth"
require "monk/websocket"
require "monk/persistence/pg"

# The generated bin/websocket_server of an --auth app, as a real process:
# it starts config/auth.rb's :auth pool and checks sessions through it, so
# its Postgres connections stay fixed however many sockets are open.
# Every connection the process opens carries PGAPPNAME's name, which
# libpq applies to any connection that doesn't set its own.
class ScaffoldWebSocketServerTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthTestHelpers
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

  def test_the_chat_server_checks_sessions_through_the_pool
    assert_connections_stay_fixed(auth: true, extra: 0)
  end

  # Its PgFanout's LISTEN is one more connection, opened at boot.
  def test_the_live_server_checks_sessions_through_the_pool
    assert_connections_stay_fixed(auth: true, live: true, postgres: true, extra: 1)
  end

  # Without --auth there's no Monk::Auth, so no pool, and no Postgres.
  def test_without_auth_the_chat_server_boots_without_a_pool
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest).write!
      port = free_port
      pid = Process.spawn(
        server_env(port, "unused"), RbConfig.ruby, "-W0", "bin/websocket_server", chdir: dest, out: File::NULL,
      )

      begin
        wait_for_port(port, pid)
        socket = TCPSocket.new("127.0.0.1", port)

        assert_equal "HTTP/1.1 101 Switching Protocols", handshake!(socket).lines.first.strip
      ensure
        socket&.close
        stop(pid)
      end
    end
  end

  private

  def assert_connections_stay_fixed(extra:, **flags)
    setup_auth_tables(:primary)
    token = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))[:token]

    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest, **flags).write!
      port = free_port
      app_name = "monk_scaffold_ws_#{SecureRandom.hex(4)}"
      pid = Process.spawn(
        server_env(port, app_name), RbConfig.ruby, "-W0", "bin/websocket_server", chdir: dest, out: File::NULL,
      )

      begin
        wait_for_port(port, pid)
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
        stop(pid)
      end
    end
  end

  # What the generated config/persistence.rb and config/auth.rb read,
  # pointed at the test database (AUTH_SECRET: setup_auth_tables's);
  # BUNDLE_GEMFILE so bundler/setup resolves monk's own bundle.
  def server_env(port, app_name)
    opts = pg_test_opts
    {
      "DB_HOST" => opts[:host], "DB_PORT" => opts[:port].to_s, "DB_USER" => opts[:user],
      "DB_PASSWORD" => opts[:password], "DB_NAME" => opts[:dbname],
      "MONK_ENV" => "test", "AUTH_SECRET" => "s3cr3t", "WS_PORT" => port.to_s, "PGAPPNAME" => app_name,
      "BUNDLE_GEMFILE" => File.expand_path("../Gemfile", __dir__),
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
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk "bin/websocket_server didn't listen within 15s"
      end
      sleep 0.05
    end
  end

  # A server that crashed at boot was already reaped by wait_for_port.
  def stop(pid)
    Process.kill("TERM", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def backend_count(app_name)
    conn = PG.connect(**pg_test_opts)
    conn.exec_params(
      "SELECT count(*) FROM pg_stat_activity WHERE application_name = $1", [app_name],
    ).getvalue(0, 0).to_i
  ensure
    conn&.close
  end
end
