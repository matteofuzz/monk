require_relative "test_helper"
require "monk/presence"

# Monk::Presence's tables and statements, against real Postgres
# (docs/adr/0019-presence-per-process-rows-in-postgres-settled-once-per-transition.md):
# rows per (process, subject), counting while the process heartbeats and
# for the grace once gone; readers derive the status; settling records
# each transition once.
class PresenceStoreTest < Minitest::Test
  include PersistenceTestHelpers
  include PresenceTestHelpers

  DB_NAME = :presence_store_test_db

  def setup
    Monk::Persistence::Pg.reset!
    skip_unless_postgres_available
    setup_presence_tables(DB_NAME)
    @store = Monk::Presence::Store.new(db_name: DB_NAME, grace: 20, process_timeout: 30)
    @process = @store.register_process(hostname: "box-1", pid: 1)
  end

  def teardown
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_presence_tables(conn) } if postgres_available?
    Monk::Persistence::Pg.reset!
  end

  def test_the_per_process_tables_are_unlogged_and_the_status_table_is_logged
    persistence = sql("SELECT relname, relpersistence FROM pg_class WHERE relname LIKE 'monk_presence%' " \
                      "AND relkind = 'r'").to_h { |r| [r["relname"], r["relpersistence"]] }

    assert_equal({ "monk_presence" => "u", "monk_presence_processes" => "u", "monk_presence_status" => "p" },
      persistence,)
  end

  def test_a_subject_without_rows_is_offline_and_never_seen
    assert_equal({ "u:1" => { status: :offline, last_seen_at: nil } }, @store.status(["u:1"]))
  end

  def test_status_is_the_best_of_the_counting_rows
    other = @store.register_process(hostname: "box-2", pid: 2)
    @store.flush(@process, online: [], away: %w[u:1 u:2])
    @store.flush(other, online: ["u:1"], away: [])

    statuses = @store.status(%w[u:1 u:2 u:3])

    assert_equal(%i[online away offline], statuses.values_at("u:1", "u:2", "u:3").map { |s| s[:status] })
  end

  def test_a_gone_row_counts_for_the_grace_with_its_last_status
    @store.flush(@process, online: [], away: ["u:1"])
    @store.flush(@process, gone: ["u:1"])

    assert_equal :away, @store.status(["u:1"])["u:1"][:status]
    age_gone(DB_NAME, @process, "u:1", 21)
    assert_equal :offline, @store.status(["u:1"])["u:1"][:status]
  end

  # Read in the tick between the rows expiring and their settling.
  def test_an_offline_subject_not_yet_settled_reads_its_last_seen_at_from_the_rows
    @store.flush(@process, online: ["u:1"], away: [])
    @store.flush(@process, gone: ["u:1"])
    gone_at = age_gone(DB_NAME, @process, "u:1", 21)

    status = @store.status(["u:1"])["u:1"]

    assert_equal :offline, status[:status]
    assert_in_delta gone_at, status[:last_seen_at], 0.001
  end

  def test_a_reconnect_inside_the_grace_counts_as_never_gone
    @store.flush(@process, online: ["u:1"], away: [])
    @store.flush(@process, gone: ["u:1"])
    @store.flush(@process, online: ["u:1"], away: [])

    assert_nil sql("SELECT gone_at FROM monk_presence").getvalue(0, 0)
    assert_equal :online, @store.status(["u:1"])["u:1"][:status]
  end

  # A crash: the rows were never marked gone, and stop counting once the
  # heartbeat is older than the process timeout.
  def test_a_silent_processs_open_rows_stop_counting_after_the_process_timeout
    @store.flush(@process, online: ["u:1"], away: [])
    age_heartbeat(DB_NAME, @process, 29)
    assert_equal :online, @store.status(["u:1"])["u:1"][:status]

    age_heartbeat(DB_NAME, @process, 2)
    assert_equal :offline, @store.status(["u:1"])["u:1"][:status]
  end

  # A stop (TERM): rows marked gone keep counting for the grace even
  # though the heartbeat has stopped, so a deploy changes nobody's status.
  def test_rows_marked_gone_by_a_stopping_process_count_for_the_grace
    @store.flush(@process, online: %w[u:1 u:2], away: [])
    @store.mark_all_gone(@process)
    age_heartbeat(DB_NAME, @process, 600)

    assert_equal(%i[online online], @store.status(%w[u:1 u:2]).values.map { |s| s[:status] })
  end

  def test_rewrite_writes_the_whole_state_and_marks_every_other_open_row_gone
    @store.flush(@process, online: %w[u:1 u:2], away: [])
    @store.flush(@process, gone: ["u:1"])

    @store.rewrite(@process, online: ["u:3"], away: ["u:1"])

    rows = sql("SELECT subject, status, gone_at IS NOT NULL AS gone FROM monk_presence ORDER BY subject")
    assert_equal([%w[u:1 away f], %w[u:2 online t], %w[u:3 online f]],
      rows.map { |r| [r["subject"], r["status"], r["gone"] ? "t" : "f"] },)
  end

  def test_heartbeat_says_whether_the_process_row_had_to_be_restored
    refute @store.heartbeat(@process, hostname: "box-1", pid: 1)
    sql("DELETE FROM monk_presence_processes")

    assert @store.heartbeat(@process, hostname: "box-1", pid: 1)
    assert_equal 1, sql("SELECT count(*) FROM monk_presence_processes").getvalue(0, 0)
  end

  def test_a_transition_is_settled_once
    @store.flush(@process, online: ["u:1"], away: [])

    assert_equal [["u:1", :online, nil]], transitions(@store.settle(["u:1"]))
    assert_empty @store.settle(["u:1"])
    other = Monk::Presence::Store.new(db_name: DB_NAME, grace: 20, process_timeout: 30)
    assert_empty other.settle(["u:1"]), "another process settling the same subject sees no change"
  end

  def test_online_to_away_and_back_are_transitions
    @store.flush(@process, online: ["u:1"], away: [])
    @store.settle(["u:1"])

    @store.flush(@process, online: [], away: ["u:1"])
    assert_equal [["u:1", :away, nil]], transitions(@store.settle(["u:1"]))
    @store.flush(@process, online: ["u:1"], away: [])
    assert_equal [["u:1", :online, nil]], transitions(@store.settle(["u:1"]))
  end

  def test_going_offline_is_settled_after_the_grace_with_last_seen_at_and_the_row_pruned
    @store.flush(@process, online: ["u:1"], away: [])
    @store.settle(["u:1"])
    @store.flush(@process, gone: ["u:1"])
    assert_empty @store.settle(["u:1"]), "still inside the grace"

    gone_at = age_gone(DB_NAME, @process, "u:1", 21)
    settled = @store.settle([])

    assert_equal([["u:1", :offline]], settled.map { |t| [t.subject, t.status] })
    assert_in_delta gone_at, settled.first.last_seen_at, 0.001
    assert_equal 0, sql("SELECT count(*) FROM monk_presence").getvalue(0, 0)
    assert_equal({ status: :offline, last_seen_at: settled.first.last_seen_at }, @store.status(["u:1"])["u:1"])
  end

  def test_a_reconnect_inside_the_grace_settles_nothing
    @store.flush(@process, online: ["u:1"], away: [])
    @store.settle(["u:1"])
    @store.flush(@process, gone: ["u:1"])
    @store.settle(["u:1"])
    @store.flush(@process, online: ["u:1"], away: [])

    assert_empty @store.settle(["u:1"])
  end

  def test_a_dead_processs_subjects_go_offline_last_seen_at_its_last_heartbeat_and_it_is_pruned
    @store.flush(@process, online: ["u:1"], away: [])
    @store.settle(["u:1"])
    heartbeat_at = age_heartbeat(DB_NAME, @process, 31)

    settled = @store.settle([])

    assert_equal([["u:1", :offline]], settled.map { |t| [t.subject, t.status] })
    assert_in_delta heartbeat_at, settled.first.last_seen_at, 0.001
    assert_equal 0, sql("SELECT count(*) FROM monk_presence_processes").getvalue(0, 0)
  end

  def test_a_subject_with_rows_elsewhere_stays_online_when_one_process_dies
    other = @store.register_process(hostname: "box-2", pid: 2)
    @store.flush(@process, online: ["u:1"], away: [])
    @store.flush(other, online: ["u:1"], away: [])
    @store.settle(["u:1"])
    age_heartbeat(DB_NAME, @process, 31)

    assert_empty @store.settle([])
    assert_equal :online, @store.status(["u:1"])["u:1"][:status]
  end

  def test_a_subject_never_settled_online_gets_no_offline_row
    @store.flush(@process, online: ["u:1"], away: [])
    @store.flush(@process, gone: ["u:1"])
    age_gone(DB_NAME, @process, "u:1", 21)

    assert_empty @store.settle(["u:1"])
    assert_equal 0, sql("SELECT count(*) FROM monk_presence_status").getvalue(0, 0)
  end

  # Postgres crashed: the unlogged rows are gone, nothing expires, and
  # only the full reconcile finds the stored statuses stale.
  def test_reconcile_settles_subjects_whose_rows_vanished
    @store.flush(@process, online: ["u:1"], away: [])
    @store.settle(["u:1"])
    sql("TRUNCATE monk_presence, monk_presence_processes")

    assert_empty @store.settle([])
    settled = @store.settle([], reconcile: true)
    assert_equal([["u:1", :offline]], settled.map { |t| [t.subject, t.status] })
    refute_nil settled.first.last_seen_at
  end

  # The signal bin/server's reactor waits for: one notify per settle,
  # listing the subjects whose status changed, sent with the commit.
  def test_settle_with_notify_signals_the_changed_subjects_once
    listening do |listener|
      @store.flush(@process, online: %w[u:1 u:2], away: [])

      @store.settle(%w[u:1 u:2], notify: true)
      @store.settle(%w[u:1 u:2], notify: true)

      assert_equal [%w[u:1 u:2]], notifies(listener).map(&:sort)
    end
  end

  def test_settle_without_notify_signals_nothing
    listening do |listener|
      @store.flush(@process, online: ["u:1"], away: [])

      @store.settle(["u:1"])

      assert_empty notifies(listener)
    end
  end

  def test_a_large_change_is_signalled_in_notifies_that_fit_postgres_limit
    subjects = Array.new(2000) { |i| "user:#{100_000 + i}" }
    listening do |listener|
      @store.flush(@process, online: subjects, away: [])

      @store.settle(subjects, notify: true)

      received = notifies(listener)
      assert_operator received.size, :>, 1
      assert_equal subjects.sort, received.flatten.sort
    end
  end

  def test_signals_split_subjects_into_payloads_under_8000_bytes
    payloads = Monk::Presence::Store.signals(Array.new(3000) { |i| "user:#{i}" })

    assert(payloads.all? { |p| p.bytesize < 8000 })
    assert_equal(3000, payloads.sum { |p| JSON.parse(p).size })
  end

  private

  def sql(query) = Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec(query) }

  def listening
    listener = PG.connect(**Monk::Persistence::Pg.connection_options(DB_NAME))
    listener.exec("LISTEN monk_presence")
    yield listener
  ensure
    listener&.close
  end

  def notifies(listener)
    received = []
    while listener.wait_for_notify(0.2) { |_channel, _pid, payload| received << JSON.parse(payload) }
    end
    received
  end

  def transitions(settled) = settled.map { |t| [t.subject, t.status, t.last_seen_at] }
end
