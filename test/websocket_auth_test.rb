require_relative "test_helper"
require "monk/auth"
require "monk/websocket"
require "socket"
require "open3"

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
end
