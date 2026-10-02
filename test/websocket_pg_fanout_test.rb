require_relative "test_helper"
require "timeout"
require "securerandom"
require "monk/websocket"
require "monk/websocket/pg_fanout"

# PgFanout wraps a Registry for cross-process fan-out, the Postgres
# LISTEN/NOTIFY counterpart to RedisFanout (docs/design/live-pg-fanout.md,
# docs/history/plan-live-pg-fanout.md). It has to be usable the exact way
# Registry and RedisFanout already are -- held behind a module constant,
# read from every connection's own Ractor -- with plain delegation for
# #register/#unregister/#count, #broadcast has to deliver locally and
# publish via pg_notify while respecting Postgres's own payload cap, and
# its subscriber Ractor has to actually relay a sibling instance's
# broadcast while dropping its own echo. It listens only once #listen! is
# called -- by the one process that holds sockets -- so a publish-only
# process opens no LISTEN connection at all. Every test skips without a
# local Postgres.
class WebSocketPgFanoutTest < Minitest::Test
  include PersistenceTestHelpers

  def teardown
    Monk::Persistence::Pg.reset!
  end

  def test_a_fanout_instance_is_frozen_and_ractor_shareable
    skip_unless_postgres_available

    fanout = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts)

    assert fanout.frozen?
    assert Ractor.shareable?(fanout), "expected PgFanout to be Ractor-shareable, same as Registry"
  end

  # The real-world shape this exists for: an app holds PgFanout behind a
  # module constant, read from inside a connection's own dedicated Ractor
  # -- which raises Ractor::IsolationError unless the constant's value is
  # shareable.
  def test_a_fanout_instance_is_readable_as_a_module_constant_from_a_worker_ractor
    skip_unless_postgres_available

    fanout = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts)
    holder = Module.new
    holder.const_set(:REGISTRY, fanout)

    result = Ractor.new(holder) { |h| h::REGISTRY.count(:room1) }.value

    assert_equal 0, result
  end

  def test_register_unregister_and_count_delegate_to_the_wrapped_registry
    skip_unless_postgres_available

    registry = Monk::WebSocket::Registry.new
    fanout = Monk::WebSocket::PgFanout.new(registry, pg_opts: pg_test_opts).listen!
    port = Ractor::Port.new

    fanout.register(:room1, port)
    assert_equal 1, fanout.count(:room1)

    fanout.unregister(:room1, port)
    assert_equal 0, fanout.count(:room1)
  ensure
    port&.close
  end

  # A publish-only process (bin/server, bin/jobs) builds the same fanout
  # from the same config/live.rb, and never needs to hear other processes'
  # broadcasts -- so constructing one mustn't LISTEN.
  def test_constructing_opens_no_listen_connection
    skip_unless_postgres_available

    before = listener_count
    Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts)

    assert_equal before, listener_count
  end

  # #listen! returns once the LISTEN is in effect, so a broadcast sent right
  # after it can't be missed -- and calling it again changes nothing.
  def test_listen_bang_opens_one_listen_connection_and_is_idempotent
    skip_unless_postgres_available

    fanout = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts)
    before = listener_count

    assert_same fanout, fanout.listen!
    assert_equal before + 1, listener_count

    fanout.listen!
    assert_equal before + 1, listener_count
  end

  # A socket registered on a fanout that isn't listening would never get
  # another process's broadcasts -- silently. Raising turns a missing
  # #listen! into an error at the first subscription.
  def test_register_before_listen_bang_raises
    skip_unless_postgres_available

    fanout = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts)
    port = Ractor::Port.new

    error = assert_raises(Monk::WebSocket::NotListeningError) { fanout.register(:room1, port) }
    assert_match(/listen!/, error.message)
  ensure
    port&.close
  end

  # The LISTEN connection is opened by #listen!, in the WS process's boot --
  # an unreachable Postgres fails it right there, not in a background
  # Ractor nobody watches.
  def test_listen_bang_raises_when_postgres_is_unreachable
    skip_unless_postgres_available

    fanout = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts.merge(port: 1))

    error = assert_raises(Monk::WebSocket::ListenError) { fanout.listen! }
    assert_match(/PgFanout/, error.message)
    assert_raises(Monk::WebSocket::NotListeningError) { fanout.register(:room1, Ractor::Port.new) }
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

  def test_broadcast_from_one_instance_reaches_a_connection_registered_on_a_sibling_instance
    skip_unless_postgres_available

    fanout_a = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts)
    fanout_b = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts).listen!

    port = Ractor::Port.new
    fanout_b.register(:room1, port)
    received = []
    reader = Thread.new { loop { received << port.receive } }

    fanout_a.broadcast(:room1, "hello from A")

    wait_until { received.any? }
    assert_equal ["hello from A"], received
  ensure
    reader&.kill
    port&.close
  end

  # Without the origin tag, A's own subscriber would relay A's own
  # broadcast back into registry_a a second time -- a connection
  # registered directly on registry_a would see it twice.
  def test_a_fanouts_own_broadcast_is_not_delivered_twice_to_its_own_registry
    skip_unless_postgres_available

    fanout_a = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts).listen!
    # A second listening instance on the same Postgres, standing in for a
    # sibling process, so A's notify really goes out and comes back -- A's
    # own subscriber is the one that must drop it.
    Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts).listen!

    port = Ractor::Port.new
    fanout_a.register(:room1, port)
    received = []
    reader = Thread.new { loop { received << port.receive } }

    fanout_a.broadcast(:room1, "only once")

    wait_until { received.any? }
    # Give a wrongly-undropped echo time to complete its round trip
    # through Postgres and arrive -- if the origin-tag guard were removed,
    # it would show up here as a second entry.
    sleep 0.3
    assert_equal ["only once"], received
  ensure
    reader&.kill
    port&.close
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

  # plan-pg-reconnect.md, phase 5: the LISTEN connection is dropped. Its
  # subscriber reconnects and LISTENs again, so a broadcast from another
  # process sent after that still arrives.
  def test_the_listener_reconnects_after_its_backend_is_terminated
    skip_unless_postgres_available

    fanout_a = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts)
    fanout_b, listen_pid = listening_fanout
    port = Ractor::Port.new
    fanout_b.register(:room1, port)
    received = []
    reader = Thread.new { loop { received << port.receive } }

    terminate_backend(listen_pid)
    wait_until(timeout: 5) { (listen_pids - [listen_pid]).size > @other_listeners.size }
    wait_until { received.any? } # the CloseRequest after the reconnect
    fanout_a.broadcast(:room1, "after the drop")

    wait_until { received.include?("after the drop") }
  ensure
    reader&.kill
    port&.close
  end

  # Notifies sent while the listener was down are lost, and no client can
  # tell, so after reconnecting every open socket is asked to close: its
  # client reconnects and resyncs.
  def test_after_reconnecting_the_listener_asks_every_open_socket_to_close
    skip_unless_postgres_available

    fanout, listen_pid = listening_fanout
    port = Ractor::Port.new
    fanout.register(:room1, port)

    terminate_backend(listen_pid)

    message = Timeout.timeout(5) { port.receive }
    assert_equal Monk::WebSocket::CloseRequest.new(code: 1011, reason: "missed broadcasts"), message
  ensure
    port&.close
  end

  def test_a_malformed_notify_is_skipped_and_the_next_one_still_arrives
    skip_unless_postgres_available

    fanout_a = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts)
    fanout_b, = listening_fanout
    port = Ractor::Port.new
    fanout_b.register(:room1, port)
    received = []
    reader = Thread.new { loop { received << port.receive } }

    conn = PG.connect(**pg_test_opts)
    conn.exec_params("SELECT pg_notify($1, $2)", [Monk::WebSocket::PgFanout::CHANNEL, "not an envelope"])
    fanout_a.broadcast(:room1, "after the bad one")

    wait_until { received.any? }
    assert_equal ["after the bad one"], received
  ensure
    conn&.close
    reader&.kill
    port&.close
  end

  # -- db_pool: (docs/history/plan-pg-pool.md, phase 9) --
  # The publisher through a pool of one worker, instead of one connection
  # per Ractor that publishes.

  def test_a_fanout_with_db_pool_publishes_through_the_pool
    start_notify_pool(size: 1)
    publisher = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, db_pool: :notify)
    listener, = listening_fanout
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
    listener, = listening_fanout
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

  # Backends whose last statement was this fanout's LISTEN: pg_stat_activity
  # keeps an idle backend's last query text (test/support/live_ws_process_pg.rb).
  def listener_count
    conn = PG.connect(**pg_test_opts)
    conn.exec_params(
      "SELECT count(*) FROM pg_stat_activity WHERE query = $1 AND datname = current_database()",
      ["LISTEN #{Monk::WebSocket::PgFanout::CHANNEL}"],
    ).getvalue(0, 0).to_i
  ensure
    conn&.close
  end

  # A fanout that has called #listen!, and its LISTEN backend's pid --
  # told apart from the listeners earlier tests left running in this
  # process, which are kept in @other_listeners.
  def listening_fanout
    @other_listeners = listen_pids
    fanout = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts).listen!
    [fanout, (listen_pids - @other_listeners).first]
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
