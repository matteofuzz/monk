require_relative "test_helper"
require "timeout"
require "securerandom"
require "monk/websocket"
require "monk/websocket/pg_fanout"
require_relative "support/fanout_contract"
require "socket"

# A socket handler that broadcasts, as a chat's does: its Ractor opens a
# publisher connection. Module scope, so it's Ractor-shareable.
module PgFanoutPublisherHandler
  BROADCAST = proc do |connection|
    connection.read
    PgFanoutPublisherHandler::FANOUT.broadcast(:room1, "hello")
    connection.write("sent")
    connection.read # holds the socket open until the client closes it
  end
end

# PgFanout: the fan-out over Postgres LISTEN/NOTIFY
# (docs/design/live-pg-fanout.md). Everything it shares with RedisFanout
# is in FanoutContract; here, what is Postgres's own: the NOTIFY payload
# cap, the publisher connection, and publishing through a pool.
class WebSocketPgFanoutTest < Minitest::Test
  include PersistenceTestHelpers
  include WebSocketTestHelpers
  include FanoutContract

  def teardown
    super # WebSocketTestHelpers: stops the server thread
    Monk::Persistence::Pg.reset!
  end

  def test_constructing_with_a_non_shareable_registry_raises
    skip_unless_postgres_available

    assert_raises(ArgumentError) do
      Monk::WebSocket::PgFanout.new(Object.new, pg_opts: pg_test_opts)
    end
  end

  def test_broadcast_delivers_to_the_local_registry_and_publishes_via_pg_notify
    skip_unless_postgres_available

    registry = Monk::WebSocket::Registry.new
    fanout = Monk::WebSocket::PgFanout.new(registry, pg_opts: pg_test_opts)
    port = Ractor::Port.new
    registry.register(:room1, port)

    fanout.broadcast(:room1, "hello")

    assert_equal "hello", port.receive
  ensure
    port&.close
  end

  # The wire limit is on the full envelope (length-prefixed origin + key,
  # plus the app payload), not the app payload alone, and it's exclusive
  # -- verified directly against Postgres (see MAX_NOTIFY_PAYLOAD_BYTES's
  # comment): an envelope of exactly MAX_NOTIFY_PAYLOAD_BYTES - 1 bytes
  # must still succeed, MAX_NOTIFY_PAYLOAD_BYTES bytes must raise before
  # pg_notify ever runs. Measures the real framing overhead via the
  # private encoder rather than re-deriving its digit-prefix math by hand,
  # so this test doesn't silently drift from the actual format.
  def test_broadcast_raises_past_the_notify_payload_cap_but_not_exactly_at_it
    skip_unless_postgres_available

    fanout = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts)
    key = :room1
    overhead = fanout.send(:envelope_for, key, "").bytesize
    at_cap = "a" * (Monk::WebSocket::PgFanout::MAX_NOTIFY_PAYLOAD_BYTES - 1 - overhead)

    fanout.broadcast(key, at_cap)

    assert_raises(Monk::WebSocket::PayloadTooLargeError) do
      fanout.broadcast(key, "#{at_cap}a")
    end
  end

  # plan-pg-reconnect.md, phase 4: the publisher connection (one per
  # Ractor that broadcasts) is dropped between two broadcasts, as when
  # Postgres restarts while a web worker sits idle. The next broadcast
  # reconnects instead of raising PG::ConnectionBad from then on.
  def test_broadcast_reconnects_after_the_publishers_backend_is_terminated
    skip_unless_postgres_available

    fanout_a = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts)
    fanout_b = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts).listen!
    port = Ractor::Port.new
    fanout_b.register(:room1, port)
    received = []
    reader = Thread.new { loop { received << port.receive } }

    fanout_a.broadcast(:room1, "before the drop")
    wait_until { received.size == 1 }
    terminate_backend(publisher_pid)

    fanout_a.broadcast(:room1, "after the drop")

    wait_until { received.size == 2 }
    assert_equal ["before the drop", "after the drop"], received
  ensure
    reader&.kill
    port&.close
  end

  def test_the_publisher_connection_gets_the_default_connect_timeout
    skip_unless_postgres_available

    Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts).broadcast(:room1, "x")

    assert_equal "5", Ractor.current[:monk_pg_fanout_publisher].conninfo_hash[:connect_timeout]
  end

  # A socket's Ractor that broadcast opened a publisher connection: it's
  # closed when the socket ends, not left for the garbage collector.
  def test_a_closed_sockets_publisher_connection_is_closed
    skip_unless_postgres_available
    application_name = "monk_fanout_publisher_#{SecureRandom.hex(4)}"
    fanout = Monk::WebSocket::PgFanout.new(
      Monk::WebSocket::Registry.new, pg_opts: pg_test_opts.merge(application_name: application_name),
    )
    PgFanoutPublisherHandler.const_set(:FANOUT, fanout)
    server = start_server(&PgFanoutPublisherHandler::BROADCAST)
    count = -> { backend_count(application_name) }
    GC.disable

    sockets = Array.new(3) do
      TCPSocket.new("127.0.0.1", server.port).tap do |socket|
        handshake!(socket)
        socket.write(Monk::WebSocket::Frame.encode("go", opcode: 0x1))
        read_frame(socket)
      end
    end
    assert_equal 3, count.call, "control: each socket that broadcast holds one"

    sockets.each(&:close)

    wait_until(timeout: 3) { count.call.zero? }
  ensure
    GC.enable
    sockets&.each { |socket| socket.close unless socket.closed? }
    PgFanoutPublisherHandler.send(:remove_const, :FANOUT) if PgFanoutPublisherHandler.const_defined?(:FANOUT)
  end

  # -- db_pool: (docs/history/plan-pg-pool.md, phase 9) --
  # The publisher through a pool of one worker, instead of one connection
  # per Ractor that publishes.

  def test_a_fanout_with_db_pool_publishes_through_the_pool
    start_notify_pool(size: 1)
    publisher = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, db_pool: :notify)
    listener = listening_fanout
    port = Ractor::Port.new
    listener.register(:room1, port)

    publisher.broadcast(:room1, "through the pool")

    assert_equal "through the pool", Timeout.timeout(3) { port.receive }
  ensure
    port&.close
  end

  def test_ractors_publishing_through_the_pool_share_its_one_connection
    start_notify_pool(size: 1)
    publisher = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, db_pool: :notify)

    Array.new(4) { Ractor.new(publisher) { |fanout| 5.times { |i| fanout.broadcast(:room1, "n#{i}") } } }.each(&:join)

    assert_equal 1, notify_pool_connection_count
  end

  # Patches to a page must arrive in the order they were published.
  def test_one_senders_broadcasts_arrive_in_order
    start_notify_pool(size: 1)
    publisher = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, db_pool: :notify)
    listener = listening_fanout
    port = Ractor::Port.new
    listener.register(:room1, port)

    (1..50).each { |n| publisher.broadcast(:room1, n.to_s) }

    assert_equal((1..50).map(&:to_s), Array.new(50) { Timeout.timeout(3) { port.receive } })
  ensure
    port&.close
  end

  def test_a_pool_larger_than_one_is_refused_naming_the_order_rule
    start_notify_pool(size: 2)

    error = assert_raises(ArgumentError) { Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, db_pool: :notify) }

    assert_match(/size 1/, error.message)
    assert_match(/order/, error.message)
  end

  def test_pg_opts_or_db_pool_but_not_both_nor_neither
    start_notify_pool(size: 1)

    assert_raises(ArgumentError) do
      Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts, db_pool: :notify)
    end
    assert_raises(ArgumentError) { Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new) }
  end

  # The WebSocket process builds the same fanout from the same config, and
  # LISTENs: with db_pool: only, it LISTENs on the pool's database.
  def test_a_fanout_with_db_pool_can_listen
    start_notify_pool(size: 1)
    fanout = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, db_pool: :notify).listen!
    port = Ractor::Port.new
    fanout.register(:room1, port)

    Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts).broadcast(:room1, "heard")

    assert_equal "heard", Timeout.timeout(3) { port.receive }
  ensure
    port&.close
  end

  private

  def start_notify_pool(size:)
    skip_unless_postgres_available
    Monk::Persistence::Pg.reset!
    @notify_application_name = "monk_notify_pool_#{SecureRandom.hex(4)}"
    Monk::Persistence::Pg.register(:notify_db, **pg_test_opts, application_name: @notify_application_name)
    Monk::Persistence::Pg.pool(:notify, db: :notify_db, size: size)
    Monk::Persistence::Pg.start_pools!(:notify)
  end

  def notify_pool_connection_count
    conn = PG.connect(**pg_test_opts)
    result = conn.exec_params(
      "SELECT count(*) FROM pg_stat_activity WHERE application_name = $1", [@notify_application_name],
    )
    result.getvalue(0, 0).to_i
  ensure
    conn&.close
  end

  def fanout_class = Monk::WebSocket::PgFanout
  def new_fanout(registry = Monk::WebSocket::Registry.new) = fanout_class.new(registry, pg_opts: pg_test_opts)
  def skip_unless_transport_available = skip_unless_postgres_available
  def current_publisher = Ractor.current[:monk_pg_fanout_publisher]
  def publisher_closed?(conn) = conn.finished?
  def drop_listener = terminate_backend(@listen_pid)

  def unreachable_fanout
    skip_unless_postgres_available # for pg_test_opts
    fanout_class.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts.merge(port: 1))
  end

  # Backends whose last statement was this fanout's LISTEN: pg_stat_activity
  # keeps an idle backend's last query text (test/support/live_ws_process_pg.rb).
  def subscriber_count = listen_pids.size

  # A listening fanout, and its LISTEN backend's pid for #drop_listener,
  # told apart from the listeners earlier tests left running.
  def listening_fanout
    others = listen_pids
    fanout = new_fanout.listen!
    @listen_pid = (listen_pids - others).first
    fanout
  end

  def publish_malformed(_key)
    conn = PG.connect(**pg_test_opts)
    conn.exec_params("SELECT pg_notify($1, $2)", [fanout_class::CHANNEL, "not an envelope"])
  ensure
    conn&.close
  end

  def listen_pids
    conn = PG.connect(**pg_test_opts)
    conn.exec_params(
      "SELECT pid FROM pg_stat_activity WHERE query = $1 AND datname = current_database()",
      ["LISTEN #{Monk::WebSocket::PgFanout::CHANNEL}"],
    ).column_values(0)
  ensure
    conn&.close
  end

  # This Ractor's publisher connection, opened by its first #broadcast.
  def backend_count(application_name)
    conn = PG.connect(**pg_test_opts)
    conn.exec_params(
      "SELECT count(*) FROM pg_stat_activity WHERE application_name = $1", [application_name],
    ).getvalue(0, 0).to_i
  ensure
    conn&.close
  end

  def publisher_pid
    Ractor.current[:monk_pg_fanout_publisher].backend_pid
  end

  def wait_until(timeout: 2.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end
end
