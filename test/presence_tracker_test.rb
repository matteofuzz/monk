require_relative "test_helper"
require "monk/presence"

# A WebSocket process's presence tick (ADR 0019): take what changed from
# the counts, flush it, settle, and signal each transition once. Ticks are
# driven by hand here, collecting what each settled; Tracker#run calls
# #tick once a second.
class PresenceTrackerTest < Minitest::Test
  include PersistenceTestHelpers
  include PresenceTestHelpers

  DB_NAME = :presence_tracker_test_db

  def setup
    Monk::Persistence::Pg.reset!
    skip_unless_postgres_available
    setup_presence_tables(DB_NAME)
    @store = Monk::Presence::Store.new(db_name: DB_NAME, grace: 20, process_timeout: 30)
    @settled = []
  end

  def teardown
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_presence_tables(conn) } if postgres_available?
    Monk::Persistence::Pg.reset!
  end

  def test_a_connect_is_flushed_and_settled_once
    counts, tracker = tracker_for("box-1")
    counts.open(:s1, "u:1")

    tick(tracker)
    tick(tracker)

    assert_equal [["u:1", :online, nil]], changes
    assert_equal :online, @store.status(["u:1"])["u:1"][:status]
  end

  def test_two_processes_settle_a_subject_once
    counts1, tracker1 = tracker_for("box-1")
    counts2, tracker2 = tracker_for("box-2")
    counts1.open(:s1, "u:1")
    counts2.open(:s2, "u:1")

    tick(tracker1)
    tick(tracker2)

    assert_equal [["u:1", :online, nil]], changes
  end

  def test_a_reconnect_to_another_process_inside_the_grace_settles_nothing
    counts1, tracker1 = tracker_for("box-1")
    counts2, tracker2 = tracker_for("box-2")
    counts1.open(:s1, "u:1")
    tick(tracker1)
    changes

    counts1.close(:s1)
    tick(tracker1)
    counts2.open(:s2, "u:1")
    tick(tracker2)
    process1 = tracker1.process_id
    age_gone(DB_NAME, process1, "u:1", 21)
    tick(tracker1)
    tick(tracker2)

    assert_empty changes
    assert_equal :online, @store.status(["u:1"])["u:1"][:status]
  end

  def test_offline_is_settled_after_the_grace_with_last_seen_at
    counts, tracker = tracker_for("box-1")
    counts.open(:s1, "u:1")
    tick(tracker)
    counts.close(:s1)
    tick(tracker)
    gone_at = age_gone(DB_NAME, tracker.process_id, "u:1", 21)
    changes

    tick(tracker)

    (subject, status, last_seen_at), = changes
    assert_equal ["u:1", :offline], [subject, status]
    assert_in_delta gone_at, last_seen_at, 0.001
  end

  def test_a_stopping_process_marks_its_rows_gone_so_its_subjects_stay_online_for_the_grace
    counts, tracker = tracker_for("box-1")
    counts.open(:s1, "u:1")
    tick(tracker)

    tracker.stop

    assert_equal :online, @store.status(["u:1"])["u:1"][:status]
    refute_nil count_gone(tracker.process_id)
  end

  def test_with_notify_each_transition_is_signalled_once_across_processes
    listener = PG.connect(**Monk::Persistence::Pg.connection_options(DB_NAME))
    listener.exec("LISTEN monk_presence")
    counts1, tracker1 = tracker_for("box-1", notify: true)
    counts2, tracker2 = tracker_for("box-2", notify: true)
    counts1.open(:s1, "u:1")
    counts2.open(:s2, "u:1")

    tick(tracker1)
    tick(tracker2)

    received = []
    while listener.wait_for_notify(0.2) { |_channel, _pid, payload| received << JSON.parse(payload) }
    end
    assert_equal [["u:1"]], received
  ensure
    listener&.close
  end

  # Postgres went away mid-tick: the flush that failed is gone with it,
  # so the next tick writes the whole state, closes included.
  def test_after_a_failed_tick_the_next_one_rewrites_the_whole_state
    counts, tracker = tracker_for("box-1")
    counts.open(:s1, "u:1")
    counts.open(:s2, "u:2")
    tick(tracker)

    counts.close(:s1)
    counts.open(:s3, "u:3")
    broken = Class.new(SimpleDelegator) { def flush(*, **) = raise(PG::ConnectionBad, "gone") }.new(@store)
    tracker.instance_variable_set(:@store, broken)
    with_log { tracker.tick }
    tracker.instance_variable_set(:@store, @store)
    tick(tracker)

    rows = Monk::Persistence::Pg.checkout(DB_NAME) do |c|
      c.exec("SELECT subject, gone_at IS NOT NULL AS gone FROM monk_presence ORDER BY subject").to_a
    end
    assert_equal([["u:1", true], ["u:2", false], ["u:3", false]], rows.map { |r| [r["subject"], r["gone"]] })
  end

  # The process row was pruned (it stalled past the timeout), and its
  # presence rows with it: the heartbeat brings it back and the next
  # tick writes them all again.
  def test_a_pruned_process_writes_its_rows_again
    counts, tracker = tracker_for("box-1")
    counts.open(:s1, "u:1")
    tick(tracker)
    Monk::Persistence::Pg.checkout(DB_NAME) { |c| c.exec("TRUNCATE monk_presence, monk_presence_processes") }

    tracker.heartbeat_now!
    tick(tracker)

    assert_equal :online, @store.status(["u:1"])["u:1"][:status]
  end

  private

  def tracker_for(hostname, notify: false)
    counts = Monk::Presence::Counts.new(start_visible: true)
    tracker = Monk::Presence::Tracker.new(store: @store, counts: counts, notify: notify, hostname: hostname)
    tracker.start
    [counts, tracker]
  end

  def tick(tracker)
    @settled.concat(tracker.tick)
  end

  # What was settled since the last call.
  def changes
    @settled.slice!(0..).map { |t| [t.subject, t.status, t.last_seen_at] }
  end

  def count_gone(process_id)
    Monk::Persistence::Pg.checkout(DB_NAME) do |c|
      c.exec_params("SELECT gone_at FROM monk_presence WHERE process_id = $1", [process_id]).getvalue(0, 0)
    end
  end
end
