require_relative "test_helper"
require "monk/auth"
require "monk/websocket"
require "socket"
require "open3"
require "securerandom"

class WebSocketAuthTest < Minitest::Test
  include WebSocketTestHelpers
  include PersistenceTestHelpers
  include AuthTestHelpers

  DB_NAME = :websocket_auth_test_db

  ECHO_ONE_MESSAGE = proc do |connection|
    message = connection.read
    connection.write(message) if message
  end

  # Replies with who the server decided this connection belongs to.
  WHO_AM_I = proc do |connection|
    connection.read
    connection.write(connection.subject || "anonymous")
  end

  def setup
    Monk::Persistence::Pg.reset!
  end

  def teardown
    super
    if postgres_available?
      begin
        Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_auth_tables(conn) }
      rescue Monk::UnknownPersistenceError
      end
    end
    Monk::Persistence::Pg.reset!
    Monk::Auth.reset!
  end

  def status_line(response)
    response.lines.first.strip
  end

  def who_am_i(socket)
    socket.write(Monk::WebSocket::Frame.encode("who?", opcode: 0x1))
    read_frame(socket)
  end

  def test_server_new_requires_monk_auth_to_already_be_configured_when_authenticate_is_true
    error = assert_raises(Monk::AuthNotConfiguredError) do
      Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1", authenticate: true)
    end
    assert_match(/already be configured/, error.message)
  end

  def test_valid_bearer_token_is_accepted_with_no_origin_check
    setup_auth_tables(DB_NAME)
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    server = start_server(authenticate: true, &ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake!(socket, extra_headers: { "Authorization" => "Bearer #{session[:token]}" })

    assert_equal "HTTP/1.1 101 Switching Protocols", status_line(response)
  ensure
    socket&.close
  end

  def test_missing_credential_gets_a_401
    setup_auth_tables(DB_NAME)
    server = start_server(authenticate: true, &ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake!(socket)

    assert_equal "HTTP/1.1 401 Unauthorized", status_line(response)
    assert_nil socket.read(1), "expected the socket to be closed after a 401"
  ensure
    socket&.close
  end

  def test_invalid_bearer_token_gets_a_401
    setup_auth_tables(DB_NAME)
    server = start_server(authenticate: true, &ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake!(socket, extra_headers: { "Authorization" => "Bearer nonsense" })

    assert_equal "HTTP/1.1 401 Unauthorized", status_line(response)
  ensure
    socket&.close
  end

  def test_valid_cookie_with_an_allowed_origin_is_accepted
    setup_auth_tables(DB_NAME)
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    server = start_server(authenticate: true, allowed_origins: ["https://example.com"], &ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake!(
      socket,
      extra_headers: { "Cookie" => "session_token=#{session[:token]}", "Origin" => "https://example.com" },
    )

    assert_equal "HTTP/1.1 101 Switching Protocols", status_line(response)
  ensure
    socket&.close
  end

  def test_valid_cookie_with_a_disallowed_origin_gets_a_403_before_verify_even_runs
    setup_auth_tables(DB_NAME)
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    server = start_server(authenticate: true, allowed_origins: ["https://example.com"], &ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake!(
      socket,
      extra_headers: { "Cookie" => "session_token=#{session[:token]}", "Origin" => "https://evil.example" },
    )

    assert_equal "HTTP/1.1 403 Forbidden", status_line(response)
  ensure
    socket&.close
  end

  def test_a_bearer_connection_is_never_origin_checked_even_with_allowed_origins_configured
    setup_auth_tables(DB_NAME)
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    server = start_server(authenticate: true, allowed_origins: ["https://example.com"], &ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake!(
      socket,
      extra_headers: { "Authorization" => "Bearer #{session[:token]}", "Origin" => "https://evil.example" },
    )

    assert_equal "HTTP/1.1 101 Switching Protocols", status_line(response)
  ensure
    socket&.close
  end

  # A real subprocess, not just this test file's own already-loaded
  # require "monk/auth" -- proves Monk::AuthNotConfiguredError is raised
  # even when an app calls authenticate: true without ever requiring
  # "monk/auth" at all, the scenario a same-process test can't exercise
  # since another test file has already loaded it.
  def test_authenticate_true_raises_a_precise_error_even_without_monk_auth_ever_required
    lib = File.expand_path("../lib", __dir__)
    script = <<~RUBY
      require "monk/websocket"
      begin
        Monk::WebSocket::Server.new(port: 0, authenticate: true)
      rescue => e
        puts e.class.name
      end
    RUBY

    stdout, _stderr, status = Open3.capture3("ruby", "-I#{lib}", "-e", script)

    assert status.success?
    assert_equal "Monk::AuthNotConfiguredError", stdout.strip

  end

  def test_reverify_interval_requires_authenticate_true
    error = assert_raises(ArgumentError) { Monk::WebSocket::Server.new(port: 0, reverify_interval: 5) }
    assert_match(/authenticate: true/, error.message)
  end

  def test_reverify_interval_must_be_positive
    error = assert_raises(ArgumentError) do
      Monk::WebSocket::Server.new(port: 0, authenticate: true, reverify_interval: 0)
    end
    assert_match(/reverify_interval/, error.message)
  end

  def test_reverify_interval_closes_the_connection_once_the_session_is_revoked
    setup_auth_tables(DB_NAME)
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    server = start_server(authenticate: true, reverify_interval: 0.05, &ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket, extra_headers: { "Authorization" => "Bearer #{session[:token]}" })

    Monk::Auth.revoke(session[:token])

    frame = read_raw_frame(socket)
    assert_equal 0x8, frame[:opcode]
  ensure
    socket&.close
  end

  def test_reverify_interval_leaves_a_still_valid_session_connected
    setup_auth_tables(DB_NAME)
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    server = start_server(authenticate: true, reverify_interval: 0.05, &ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket, extra_headers: { "Authorization" => "Bearer #{session[:token]}" })

    sleep 0.15 # a few reverify cadences, session never revoked
    socket.write(Monk::WebSocket::Frame.encode("still here", opcode: 0x1))

    assert_equal "still here", read_frame(socket)
  ensure
    socket&.close
  end

  # authenticate: :optional -- a session, when the connection carries a
  # valid one, gives it an identity; without one it's anonymous (subject
  # nil) instead of refused, and the app's own rules (Monk::Live.authorize,
  # deny by default) decide what an anonymous connection may do.

  def test_optional_lets_a_connection_without_a_credential_in_as_anonymous
    setup_auth_tables(DB_NAME)
    server = start_server(authenticate: :optional, &WHO_AM_I)

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake!(socket)

    assert_equal "HTTP/1.1 101 Switching Protocols", status_line(response)
    assert_equal "anonymous", who_am_i(socket)
  ensure
    socket&.close
  end

  def test_optional_gives_a_valid_bearer_connection_its_subject
    setup_auth_tables(DB_NAME)
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    server = start_server(authenticate: :optional, &WHO_AM_I)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket, extra_headers: { "Authorization" => "Bearer #{session[:token]}" })

    assert_equal "a@b.com", who_am_i(socket)
  ensure
    socket&.close
  end

  def test_optional_gives_a_valid_cookie_from_an_allowed_origin_its_subject
    setup_auth_tables(DB_NAME)
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    server = start_server(authenticate: :optional, allowed_origins: ["https://example.com"], &WHO_AM_I)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket, extra_headers: { "Cookie" => "session_token=#{session[:token]}", "Origin" => "https://example.com" })

    assert_equal "a@b.com", who_am_i(socket)
  ensure
    socket&.close
  end

  # A revoked or expired session -- a browser still holding the cookie
  # after logging out elsewhere -- falls back to anonymous rather than 401:
  # the page keeps its public updates, and the rules deny the private ones.
  def test_optional_treats_an_invalid_credential_as_anonymous
    setup_auth_tables(DB_NAME)
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    Monk::Auth.revoke(session[:token])
    server = start_server(authenticate: :optional, allowed_origins: ["https://example.com"], &WHO_AM_I)

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake!(socket, extra_headers: { "Cookie" => "session_token=#{session[:token]}", "Origin" => "https://example.com" })

    assert_equal "HTTP/1.1 101 Switching Protocols", status_line(response)
    assert_equal "anonymous", who_am_i(socket)
  ensure
    socket&.close
  end

  def test_optional_still_refuses_a_cookie_from_a_disallowed_origin
    setup_auth_tables(DB_NAME)
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    server = start_server(authenticate: :optional, allowed_origins: ["https://example.com"], &WHO_AM_I)

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake!(socket, extra_headers: { "Cookie" => "session_token=#{session[:token]}", "Origin" => "https://evil.example" })

    assert_equal "HTTP/1.1 403 Forbidden", status_line(response)
  ensure
    socket&.close
  end

  # Browsers always send Origin: another site's page can't open an
  # anonymous socket to this server on its visitors' behalf. A client that
  # sends no Origin at all (not a browser) still connects.
  def test_optional_refuses_an_anonymous_connection_from_a_disallowed_origin
    setup_auth_tables(DB_NAME)
    server = start_server(authenticate: :optional, allowed_origins: ["https://example.com"], &WHO_AM_I)

    refused = TCPSocket.new("127.0.0.1", server.port)
    assert_equal "HTTP/1.1 403 Forbidden", status_line(handshake!(refused, extra_headers: { "Origin" => "https://evil.example" }))

    no_origin = TCPSocket.new("127.0.0.1", server.port)
    assert_equal "HTTP/1.1 101 Switching Protocols", status_line(handshake!(no_origin))
    assert_equal "anonymous", who_am_i(no_origin)
  ensure
    refused&.close
    no_origin&.close
  end

  # reverify_interval only watches connections that have a session: an
  # anonymous one has nothing to re-check, and stays connected.
  def test_optional_with_reverify_interval_leaves_an_anonymous_connection_alone
    setup_auth_tables(DB_NAME)
    server = start_server(authenticate: :optional, reverify_interval: 0.05, &WHO_AM_I)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)
    sleep 0.15

    assert_equal "anonymous", who_am_i(socket)
  ensure
    socket&.close
  end

  def test_optional_requires_monk_auth_to_already_be_configured
    error = assert_raises(Monk::AuthNotConfiguredError) do
      Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1", authenticate: :optional)
    end
    assert_match(/authenticate: :optional/, error.message)
  end

  def test_an_unknown_authenticate_value_raises
    error = assert_raises(ArgumentError) { Monk::WebSocket::Server.new(port: 0, authenticate: :sometimes) }
    assert_match(/authenticate/, error.message)
  end

  def test_authenticate_false_skips_the_whole_identity_flow
    server = start_server(&ECHO_ONE_MESSAGE) # authenticate defaults to false, no Monk::Auth setup at all

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake!(socket)

    assert_equal "HTTP/1.1 101 Switching Protocols", status_line(response)
  ensure
    socket&.close
  end

  # Without db_pool:, a socket's Ractor opens a connection of its own to
  # verify the session. It's closed when the socket ends, not left for
  # the garbage collector, which may not run for a long time in a server
  # that mostly waits.
  def test_without_db_pool_a_closed_sockets_connection_is_closed
    setup_counted_auth
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    server = start_server(authenticate: true, &ECHO_ONE_MESSAGE)
    GC.disable

    sockets = Array.new(5) do
      TCPSocket.new("127.0.0.1", server.port).tap do |socket|
        handshake!(socket, extra_headers: { "Authorization" => "Bearer #{session[:token]}" })
      end
    end
    assert_equal 5, pooled_connection_count, "control: each open socket holds one"

    sockets.each(&:close)

    wait_until(timeout: 3) { pooled_connection_count.zero? }
  ensure
    GC.enable
    sockets&.each { |socket| socket.close unless socket.closed? }
  end

  # -- db_pool: (docs/history/plan-pg-pool.md, phase 7) --
  # Each socket runs in a Ractor of its own. Without a pool, verifying its
  # session opens a connection in that Ractor and holds it for as long as
  # the socket is open: one connection per open page.

  def test_with_db_pool_open_sockets_share_the_pools_connections
    setup_pooled_auth(size: 2)
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    server = start_server(authenticate: true, db_pool: :auth, &WHO_AM_I)

    sockets = Array.new(20) do
      TCPSocket.new("127.0.0.1", server.port).tap do |socket|
        handshake!(socket, extra_headers: { "Authorization" => "Bearer #{session[:token]}" })
      end
    end

    assert_equal(["a@b.com"] * 20, sockets.map { |socket| who_am_i(socket) })
    assert_equal 2, pooled_connection_count
  ensure
    sockets&.each(&:close)
  end

  def test_with_db_pool_an_invalid_token_still_gets_a_401
    setup_pooled_auth(size: 1)
    server = start_server(authenticate: true, db_pool: :auth, &ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake!(socket, extra_headers: { "Authorization" => "Bearer not-a-real-token" })

    assert_equal "HTTP/1.1 401 Unauthorized", status_line(response)
  ensure
    socket&.close
  end

  def test_with_db_pool_optional_identifies_through_the_pool
    setup_pooled_auth(size: 1)
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    server = start_server(authenticate: :optional, db_pool: :auth, &WHO_AM_I)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket, extra_headers: { "Authorization" => "Bearer #{session[:token]}" })

    assert_equal "a@b.com", who_am_i(socket)
    assert_equal 1, pooled_connection_count
  ensure
    socket&.close
  end

  def test_with_db_pool_reverify_runs_through_the_pool
    setup_pooled_auth(size: 1)
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    server = start_server(authenticate: true, reverify_interval: 0.05, db_pool: :auth, &ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket, extra_headers: { "Authorization" => "Bearer #{session[:token]}" })
    sleep 0.15 # a few reverify cadences
    assert_equal 1, pooled_connection_count

    Monk::Auth.revoke(session[:token])

    assert_equal 0x8, read_raw_frame(socket)[:opcode]
  ensure
    socket&.close
  end

  def test_db_pool_requires_authenticate
    error = assert_raises(ArgumentError) { Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1", db_pool: :auth) }

    assert_match(/db_pool requires authenticate/, error.message)
  end

  def test_db_pool_must_be_started_before_the_server
    setup_auth_tables(DB_NAME)
    Monk::Persistence::Pg.pool(:auth, db: DB_NAME, size: 1)

    assert_raises(Monk::PoolNotStartedError) do
      Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1", authenticate: true, db_pool: :auth)
    end
  end

  private

  # Monk::Auth on DB_NAME, with a pool of its own; pooled_connection_count
  # sees only the pool's connections.
  def setup_pooled_auth(size:)
    setup_counted_auth
    Monk::Persistence::Pg.pool(:auth, db: DB_NAME, size: size)
    Monk::Persistence::Pg.start_pools!(:auth)
  end

  # Every connection opened from here on, outside this (the test's)
  # Ractor, is counted by pooled_connection_count.
  def setup_counted_auth
    setup_auth_tables(DB_NAME)
    @application_name = "monk_ws_pool_test_#{SecureRandom.hex(4)}"
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts, application_name: @application_name)
  end

  def pooled_connection_count
    conn = PG.connect(**pg_test_opts)
    result = conn.exec_params("SELECT count(*) FROM pg_stat_activity WHERE application_name = $1", [@application_name])
    result.getvalue(0, 0).to_i
  ensure
    conn&.close
  end
end
