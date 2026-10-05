require_relative "test_helper"
require "monk/persistence/pg"
require_relative "support/tcp_proxy"

# Exercises Monk::Persistence::Registry (the backend-agnostic mixin) via
# Monk::Persistence::Pg, its only concrete backend today.
class PersistenceTest < Minitest::Test
  include PersistenceTestHelpers

  DB_NAME = :persistence_test_db

  def setup
    Monk::Persistence::Pg.reset!
  end

  def teardown
    Monk::Persistence::Pg.reset!
  end

  def test_lookup_raises_a_precise_error_for_an_unregistered_name
    error = assert_raises(Monk::UnknownPersistenceError) { Monk::Persistence::Pg[:nope] }

    assert_match(/nope/, error.message)
  end

  def test_register_then_lookup_returns_a_connection
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)

    assert_instance_of PG::Connection, Monk::Persistence::Pg[DB_NAME]
  end

  def test_lookup_memoizes_the_connection_within_the_same_ractor
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)

    first = Monk::Persistence::Pg[DB_NAME]
    second = Monk::Persistence::Pg[DB_NAME]

    assert_same first, second
  end

  def test_checkout_yields_a_usable_connection
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)

    value = Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec("SELECT 1 AS one").getvalue(0, 0) }

    assert_equal 1, value
  end

  def test_checkout_serializes_concurrent_access_and_times_out
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)

    holder = Thread.new { Monk::Persistence::Pg.checkout(DB_NAME) { sleep 0.3 } }
    sleep 0.05 # let the holder acquire the slot first

    error = assert_raises(Monk::PersistenceTimeoutError) do
      Monk::Persistence::Pg.checkout(DB_NAME, timeout: 0.1) { flunk "should not run while the slot is held" }
    end
    assert_match(/persistence_test_db/, error.message)

    holder.join
  end

  def test_checkout_releases_the_slot_after_the_holder_finishes
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)

    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec("SELECT 1") }

    value = Monk::Persistence::Pg.checkout(DB_NAME, timeout: 0.1) { |conn| conn.exec("SELECT 2 AS two").getvalue(0, 0) }
    assert_equal 2, value
  end

  # -- When the connection drops (plan-pg-reconnect.md, phase 2) --

  def test_checkout_after_the_backend_was_terminated_reconnects
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    old_pid = Monk::Persistence::Pg.checkout(DB_NAME, &:backend_pid)

    terminate_backend(old_pid)
    new_pid = Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec("SELECT pg_backend_pid()").getvalue(0, 0) }

    refute_equal old_pid, new_pid
  end

  def test_a_drop_in_the_middle_of_a_block_fails_that_block_once_and_the_next_checkout_works
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    runs = 0

    assert_raises(PG::ConnectionBad) do
      Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
        runs += 1
        terminate_backend(conn.backend_pid)
        conn.exec("SELECT 1")
      end
    end

    assert_equal 1, runs
    assert_equal 2, Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec("SELECT 2").getvalue(0, 0) }
  end

  def test_the_result_type_map_survives_a_reconnect
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    terminate_backend(Monk::Persistence::Pg.checkout(DB_NAME, &:backend_pid))

    row = Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec(%(SELECT 1::int AS n, '{"a":1}'::jsonb AS j)).first }

    assert_equal({ "n" => 1, "j" => { "a" => 1 } }, row)
  end

  def test_checkout_raises_without_hanging_while_postgres_is_unreachable_then_recovers
    skip_unless_postgres_available
    proxy = TcpProxy.new(pg_test_opts[:host], pg_test_opts[:port]).start
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts, host: "127.0.0.1", port: proxy.port)
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec("SELECT 1") }

    proxy.stop
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(PG::ConnectionBad) { Monk::Persistence::Pg.checkout(DB_NAME) { flunk "ran on a dead connection" } }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1

    proxy.start
    assert_equal 3, Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec("SELECT 3").getvalue(0, 0) }
  ensure
    proxy&.stop
  end

  def test_a_pending_notify_is_not_mistaken_for_a_drop_and_stays_queued
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    conn = Monk::Persistence::Pg[DB_NAME]
    conn.exec("LISTEN reconnect_probe")
    other = PG.connect(**pg_test_opts)
    other.exec("NOTIFY reconnect_probe, 'hello'")
    assert conn.socket_io.wait_readable(5), "the NOTIFY never arrived"

    pid, notify = Monk::Persistence::Pg.checkout(DB_NAME) { |c| [c.backend_pid, c.notifies] }

    assert_equal conn.backend_pid, pid
    assert_equal({ relname: "reconnect_probe", be_pid: other.backend_pid, extra: "hello" }, notify)
  ensure
    other&.finish
  end

  def test_connect_timeout_defaults_to_five_seconds
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)

    assert_equal "5", Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.conninfo_hash[:connect_timeout] }
  end

  def test_an_apps_own_connect_timeout_wins
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts, connect_timeout: 2)

    assert_equal "2", Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.conninfo_hash[:connect_timeout] }
  end

  def test_a_transaction_left_open_by_a_raising_block_is_rolled_back
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec("CREATE TEMP TABLE reconnect_rollback (n int)") }

    assert_raises(RuntimeError) do
      Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
        conn.exec("BEGIN")
        conn.exec("INSERT INTO reconnect_rollback VALUES (1)")
        raise "boom"
      end
    end

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      assert_equal PG::PQTRANS_IDLE, conn.transaction_status
      assert_equal 0, conn.exec("SELECT count(*) FROM reconnect_rollback").getvalue(0, 0)
    end
  end

  def test_the_probe_sees_a_dropped_connection_over_tls
    skip_unless_postgres_available
    unless PG.connect(**pg_test_opts).then { |c| c.exec("SHOW ssl").getvalue(0, 0).tap { c.finish } } == "on"
      skip "the test Postgres has ssl = off; run against one with TLS to cover the probe over TLS"
    end
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts, sslmode: "require")
    old_pid = Monk::Persistence::Pg.checkout(DB_NAME, &:backend_pid)

    terminate_backend(old_pid)

    refute_equal old_pid, Monk::Persistence::Pg.checkout(DB_NAME, &:backend_pid)
  end
end
