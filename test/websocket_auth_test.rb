require_relative "test_helper"
require "monk/auth"
require "monk/websocket"
require "socket"
require "open3"

class WebSocketAuthTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthTestHelpers

  DB_NAME = :websocket_auth_test_db
  CLIENT_KEY = "dGhlIHNhbXBsZSBub25jZQ=="

  ECHO_ONE_MESSAGE = proc do |connection|
    message = connection.read
    connection.write(message) if message
  end

  def setup
    Monk::Persistence::Pg.reset!
  end

  def teardown
    @server_thread&.kill
    @server_thread&.join
    if postgres_available?
      begin
        Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_auth_tables(conn) }
      rescue Monk::UnknownPersistenceError
      end
    end
    Monk::Persistence::Pg.reset!
    Monk::Auth.reset!
  end

  def start_server(**kwargs, &block)
    server = Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1", **kwargs)
    @server_thread = Thread.new { server.run(&block) }
    server
  end

  def handshake(socket, extra_headers: {})
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

  def status_line(response)
    response.lines.first.strip
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
    response = handshake(socket, extra_headers: { "Authorization" => "Bearer #{session[:token]}" })

    assert_equal "HTTP/1.1 101 Switching Protocols", status_line(response)
  ensure
    socket&.close
  end

  def test_missing_credential_gets_a_401
    setup_auth_tables(DB_NAME)
    server = start_server(authenticate: true, &ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake(socket)

    assert_equal "HTTP/1.1 401 Unauthorized", status_line(response)
    assert_nil socket.read(1), "expected the socket to be closed after a 401"
  ensure
    socket&.close
  end

  def test_invalid_bearer_token_gets_a_401
    setup_auth_tables(DB_NAME)
    server = start_server(authenticate: true, &ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake(socket, extra_headers: { "Authorization" => "Bearer nonsense" })

    assert_equal "HTTP/1.1 401 Unauthorized", status_line(response)
  ensure
    socket&.close
  end

  def test_valid_cookie_with_an_allowed_origin_is_accepted
    setup_auth_tables(DB_NAME)
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    server = start_server(authenticate: true, allowed_origins: ["https://example.com"], &ECHO_ONE_MESSAGE)

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake(
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
    response = handshake(
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
    response = handshake(
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

  def test_authenticate_false_skips_the_whole_identity_flow
    server = start_server(&ECHO_ONE_MESSAGE) # authenticate defaults to false, no Monk::Auth setup at all

    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake(socket)

    assert_equal "HTTP/1.1 101 Switching Protocols", status_line(response)
  ensure
    socket&.close
  end
end
