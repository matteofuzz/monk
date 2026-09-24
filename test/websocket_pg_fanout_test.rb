require_relative "test_helper"
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
# broadcast while dropping its own echo. Every test skips without a local
# Postgres: construction always opens a real connection (no lazy/offline
# path, same as RedisFanout), so every test here needs one regardless of
# which part it's exercising.
class WebSocketPgFanoutTest < Minitest::Test
  include PersistenceTestHelpers

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
    fanout = Monk::WebSocket::PgFanout.new(registry, pg_opts: pg_test_opts)
    port = Ractor::Port.new

    fanout.register(:room1, port)
    assert_equal 1, fanout.count(:room1)

    fanout.unregister(:room1, port)
    assert_equal 0, fanout.count(:room1)
  ensure
    port&.close
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

    registry_a = Monk::WebSocket::Registry.new
    registry_b = Monk::WebSocket::Registry.new
    fanout_a = Monk::WebSocket::PgFanout.new(registry_a, pg_opts: pg_test_opts)
    Monk::WebSocket::PgFanout.new(registry_b, pg_opts: pg_test_opts)
    wait_for_subscribers

    port = Ractor::Port.new
    registry_b.register(:room1, port)
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

    registry_a = Monk::WebSocket::Registry.new
    fanout_a = Monk::WebSocket::PgFanout.new(registry_a, pg_opts: pg_test_opts)
    # A second instance on the same Postgres, standing in for a sibling
    # process, so there's a live subscriber for A's notify to reach past
    # -- without it, this test would pass even with the echo guard
    # removed.
    Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_test_opts)
    wait_for_subscribers

    port = Ractor::Port.new
    registry_a.register(:room1, port)
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

  private

  # PgFanout#initialize spawns its subscriber Ractor and returns
  # immediately -- it doesn't wait for that Ractor's own LISTEN to
  # actually take effect on the Postgres server. A NOTIFY sent before this
  # window closes can simply be missed (no queue/replay for a listener
  # that isn't there yet), same as RedisFanout's own psubscribe race. A
  # fixed wait here, not a retry loop, keeps each test's later single
  # #broadcast call meaning exactly one message went out.
  def wait_for_subscribers
    sleep 0.3
  end

  def wait_until(timeout: 2.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end
end
