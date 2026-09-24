require_relative "test_helper"
require "pg" # for PersistenceTestHelpers#postgres_available? -- pg_fanout.rb requires it itself from Phase 2 on
require "monk/websocket"
require "monk/websocket/pg_fanout"

# PgFanout wraps a Registry for cross-process fan-out, the Postgres
# LISTEN/NOTIFY counterpart to RedisFanout (docs/design/live-pg-fanout.md,
# docs/history/plan-live-pg-fanout.md). Phase 1: it has to be usable the
# exact way Registry and RedisFanout already are -- held behind a module
# constant, read from every connection's own Ractor -- with plain
# delegation for #register/#unregister/#count. Every test skips without a
# local Postgres: from Phase 3 onward, construction always opens a real
# connection (no lazy/offline path, same as RedisFanout), so keeping the
# guard here too avoids two different postures in one file.
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
end
