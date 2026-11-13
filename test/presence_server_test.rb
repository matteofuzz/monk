require_relative "test_helper"
require "monk/auth"
require "monk/websocket"
require "monk/presence"
require "socket"

# Server.new(presence:) (ADR 0019): each authenticated connection is
# counted for its subject from the 101 until it closes, however it ends;
# anonymous ones aren't counted.
class PresenceServerTest < Minitest::Test
  include WebSocketTestHelpers
  include PersistenceTestHelpers
  include AuthTestHelpers

  DB_NAME = :presence_server_test_db

  HOLD_OPEN = proc do |connection|
    nil while connection.read
  end

  def setup
    Monk::Persistence::Pg.reset!
    skip_unless_postgres_available
    setup_auth_tables(DB_NAME)
    @counts = Monk::Presence::Counts.new(start_visible: true)
  end

  def teardown
    super
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_auth_tables(conn) } if postgres_available?
    Monk::Persistence::Pg.reset!
    Monk::Auth.reset!
  end

  def test_presence_needs_authentication
    error = assert_raises(ArgumentError) { Monk::WebSocket::Server.new(port: 0, presence: @counts) }
    assert_match(/presence requires authenticate/, error.message)
  end

  # The heartbeat is what closes a vanished peer's socket, and turns a
  # silent Live page hidden.
  def test_presence_needs_a_ping_interval
    error = assert_raises(ArgumentError) do
      Monk::WebSocket::Server.new(port: 0, authenticate: true, presence: @counts)
    end
    assert_match(/presence requires ping_interval/, error.message)
  end

  def test_a_connection_is_counted_for_its_subject_until_it_closes
    session = Monk::Auth.redeem(Monk::Auth.request_login("a@b.com"))
    server = start_server(authenticate: true, presence: @counts, ping_interval: 5, &HOLD_OPEN)

    socket = open_socket(server, session[:token])
    subject = wait_for_take(:online)

    socket.close
    assert_equal [subject], wait_for_take(:gone, subject)
  end

  def test_an_anonymous_connection_is_not_counted
    server = start_server(authenticate: :optional, presence: @counts, ping_interval: 5, &HOLD_OPEN)

    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)
    sleep 0.2

    assert_equal({ online: [], away: [], gone: [] }, @counts.take)
  ensure
    socket&.close
  end

  private

  def open_socket(server, token)
    socket = TCPSocket.new("127.0.0.1", server.port)
    response = handshake!(socket, extra_headers: { "Authorization" => "Bearer #{token}" })
    assert_match(/101/, response.lines.first)
    socket
  end

  # The first non-empty list under key, within a second.
  def wait_for_take(key, expected = nil)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    loop do
      found = @counts.take[key]
      return expected ? found : found.first if found.any? && (expected.nil? || found == [expected])

      flunk "nothing #{key} within a second" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end
end
