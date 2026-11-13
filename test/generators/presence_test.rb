require_relative "../test_helper"
require "socket"
require "securerandom"
require "pg"
require "monk/auth"
require "monk/presence"

# monk add presence (docs/plan-live-networks-presence.md, open question 5):
# needs auth and websocket; bin/websocket_server counts the signed-in
# sockets, config.ru starts the reactor.
class GeneratorsPresenceTest < Minitest::Test
  include GeneratorTestHelpers
  include PersistenceTestHelpers
  include AuthTestHelpers
  include PresenceTestHelpers
  include WebSocketTestHelpers

  def setup
    Monk::Persistence::Pg.reset!
    Monk::Auth.reset!
    Monk::Presence.reset!
  end

  def teardown
    super
    if postgres_available?
      Monk::Persistence::Pg.checkout(:primary) do |conn|
        drop_presence_tables(conn)
        drop_auth_tables(conn)
      end
    end
  rescue Monk::UnknownPersistenceError
    nil
  ensure
    Monk::Presence.reset!
    Monk::Persistence::Pg.reset!
    Monk::Auth.reset!
  end

  def test_adds_auth_and_websocket_first
    with_new_app(:postgres) do |dest|
      result = add_modules(dest, :presence)

      added = result.modules.select { |entry| entry[:action] == :added }.map { |entry| entry[:name] }
      assert_equal %i[mail auth websocket presence], added
    end
  end

  def test_writes_its_config_view_and_migration
    with_new_app(:presence, options: { transport: "postgres" }) do |dest|
      assert_includes generated(dest, "config/presence.rb"), "Monk::Presence.configure(db_name: :primary, grace: 20)"
      assert_includes generated(dest, "app/views/presence/_dot.erb"), %(data-presence="<%= locals[:subject] %>")
      assert_includes Dir.children(File.join(dest, "db/migrate")), "20261008143002_create_presence_tables.up.sql"
      assert_includes generated(dest, "config/load.rb"), "live presence storage"
      assert_includes generated(dest, "config.ru"), "Monk::Presence.start_reactor!"
    end
  end

  def test_the_apps_own_tests_pass
    with_new_app(:presence, options: { transport: "postgres" }) do |dest|
      with_generated_database do |env|
        out, status = run_generated_script(dest, "bin/setup_db", env)
        assert status.success?, out

        assert_generated_tests_pass(dest, env)
      end
    end
  end

  # The generated bin/websocket_server, as a real process: a signed-in Live
  # socket counts as away until its page pings, then online; after TERM
  # it stays so for the grace, while the page reconnects elsewhere.
  def test_the_websocket_server_counts_signed_in_sockets
    setup_auth_tables(:primary)
    setup_presence_tables(:primary)
    Monk::Presence.configure(db_name: :primary)
    email = "presence-#{SecureRandom.hex(4)}@example.test"
    token = Monk::Auth.redeem(Monk::Auth.request_login(email))[:token]

    with_new_app(:auth, :live, :presence, options: { transport: "postgres" }) do |dest|
      with_server(dest) do |port|
        socket = TCPSocket.new("127.0.0.1", port)
        response = handshake!(socket, extra_headers: { "Authorization" => "Bearer #{token}" })
        assert_equal "HTTP/1.1 101 Switching Protocols", response.lines.first.strip

        assert_equal :away, wait_for_status(email, :away), "a Live socket is hidden until it pings"
        send_text(socket, %({"op":"ping"}))
        assert_equal :online, wait_for_status(email, :online)
      end

      assert_equal :online, Monk::Presence.status([email])[email][:status], "within the grace after TERM"
    end
  end

  # Two WebSocket processes, one person with a page on each. A process
  # killed with -9 does no cleanup: its rows count until its heartbeat is
  # older than the process timeout (aged here instead of waited for), and
  # the person stays away through the other; with both gone, offline.
  def test_a_killed_websocket_process_stops_counting_and_another_still_does
    setup_auth_tables(:primary)
    setup_presence_tables(:primary)
    Monk::Presence.configure(db_name: :primary)
    email = "presence-#{SecureRandom.hex(4)}@example.test"
    token = Monk::Auth.redeem(Monk::Auth.request_login(email))[:token]

    with_new_app(:auth, :live, :presence, options: { transport: "postgres" }) do |dest|
      first = start_server(dest)
      second = start_server(dest)
      sockets = [first, second].map { |port, _pid| open_socket(port, token) }
      assert_equal :away, wait_for_status(email, :away)
      wait_until("a row from each process") { open_rows(email) == 2 }

      kill_and_expire(first.last)
      assert_equal :away, Monk::Presence.status([email])[email][:status], "still counted through the other"

      kill_and_expire(second.last)
      status = Monk::Presence.status([email])[email]
      assert_equal :offline, status[:status]
      refute_nil status[:last_seen_at], "seen up to the processes' last heartbeat"
    ensure
      sockets&.each(&:close)
      [first, second].each { |server| stop(server.last) if server }
    end
  end

  private

  def open_socket(port, token)
    socket = TCPSocket.new("127.0.0.1", port)
    response = handshake!(socket, extra_headers: { "Authorization" => "Bearer #{token}" })
    assert_equal "HTTP/1.1 101 Switching Protocols", response.lines.first.strip
    socket
  end

  # KILL, then its heartbeat moved past the process timeout, as if it had
  # been dead that long.
  def kill_and_expire(pid)
    process_id = Monk::Persistence::Pg.checkout(:primary) do |conn|
      conn.exec_params("SELECT id FROM monk_presence_processes WHERE pid = $1", [pid]).getvalue(0, 0).to_i
    end
    Process.kill("KILL", pid)
    Process.wait(pid)
    age_heartbeat(:primary, process_id, Monk::Presence::PROCESS_TIMEOUT + 1)
  end

  def open_rows(subject)
    Monk::Persistence::Pg.checkout(:primary) do |conn|
      conn.exec_params("SELECT count(*) FROM monk_presence WHERE subject = $1 AND gone_at IS NULL", [subject])
          .getvalue(0, 0).to_i
    end
  end

  def wait_until(what, seconds: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      flunk "timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
  end

  def wait_for_status(subject, wanted, seconds: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      status = Monk::Presence.status([subject])[subject][:status]
      return status if status == wanted || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
  end

  # A client's text frame is masked (RFC 6455); a short one is enough here.
  def send_text(socket, text)
    mask = Random.bytes(4)
    payload = text.b.bytes.each_with_index.map { |byte, index| byte ^ mask.getbyte(index % 4) }.pack("C*")
    socket.write([0x81, 0x80 | payload.bytesize].pack("CC") + mask + payload)
  end

  def with_server(dest)
    port, pid = start_server(dest)
    yield port
  ensure
    stop(pid) if pid
  end

  # [port, pid] of a generated bin/websocket_server, once it listens.
  def start_server(dest)
    port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
    opts = pg_test_opts
    env = {
      "DB_HOST" => opts[:host], "DB_PORT" => opts[:port].to_s, "DB_USER" => opts[:user],
      "DB_PASSWORD" => opts[:password], "DB_NAME" => opts[:dbname], "MONK_ENV" => "test",
      "AUTH_SECRET" => "s3cr3t", "WS_PORT" => port.to_s,
      "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__),
    }
    pid = Process.spawn(env, RbConfig.ruby, "-W0", "bin/websocket_server", chdir: dest, out: File::NULL)
    wait_for_port(port, pid)
    [port, pid]
  end

  def stop(pid)
    Process.kill("TERM", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
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
end
