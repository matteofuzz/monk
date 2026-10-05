require_relative "test_helper"
require "monk/persistence/pg/model"

class PersistenceRactorIntegrationTest < Minitest::Test
  include PersistenceTestHelpers

  DB_NAME = :persistence_ractor_integration_db

  class Widget < Monk::Persistence::Pg::Model
    self.db_name = DB_NAME
    self.table_name = "widgets"
  end

  def setup
    Monk::Persistence::Pg.reset!
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      drop_table_if_exists(conn, "widgets")
      conn.exec(
        "CREATE TABLE widgets (id SERIAL PRIMARY KEY, name TEXT NOT NULL, quantity INTEGER NOT NULL DEFAULT 0)"
      )
    end

    # Real end-to-end boot, exactly as a real app would: this is what
    # actually freezes Monk::Persistence::Pg's config registry and
    # Widget's own db_name/table_name so they're readable from a real
    # worker Ractor at all -- without it, every test below fails with
    # Ractor::IsolationError, not a connection or query error.
    app = Class.new(Monk::Base) { get("/x") { "hi" } }
    app.freeze!
  end

  def teardown
    if postgres_available?
      Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_table_if_exists(conn, "widgets") }
    end
    Monk::Persistence::Pg.reset!
  end

  def test_concurrent_real_ractors_reading_via_model_get_correct_independent_results
    seeded = (1..5).map { |i| Widget.create(name: "widget-#{i}", quantity: i) }

    ractors = seeded.map { |row| Ractor.new(Widget, row[:id]) { |model, id| model.find(id) } }
    results = ractors.map(&:value)

    assert_equal seeded.sort_by { |r| r[:id] }, results.sort_by { |r| r[:id] }
  end

  def test_concurrent_real_ractors_creating_never_lose_or_corrupt_a_write
    ractor_count = 8

    ractors = (1..ractor_count).map do |i|
      Ractor.new(Widget, i) { |model, i| model.create(name: "ractor-widget-#{i}", quantity: i) }
    end
    rows = ractors.map(&:value)

    assert_equal ractor_count, rows.map { |r| r[:id] }.uniq.size
    assert_equal (1..ractor_count).map { |i| "ractor-widget-#{i}" }.sort, rows.map { |r| r[:name] }.sort
    assert_equal ractor_count, Widget.where({}).size
  end

  def test_two_threads_in_one_real_ractor_serialize_correctly_and_time_out_under_contention
    timeout_class, value_after_release = Ractor.new(DB_NAME) do |db_name|
      holder = Thread.new { Monk::Persistence::Pg.checkout(db_name) { sleep 0.3 } }
      sleep 0.05 # let the holder acquire the slot first

      outcome =
        begin
          Monk::Persistence::Pg.checkout(db_name, timeout: 0.1) { :should_not_run }
        rescue Monk::PersistenceTimeoutError => e
          e
        end

      holder.join # release the slot
      after_release = Monk::Persistence::Pg.checkout(db_name) { |conn| conn.exec("SELECT 1").getvalue(0, 0) }

      [outcome.class, after_release]
    end.value

    assert_equal Monk::PersistenceTimeoutError, timeout_class
    assert_equal 1, value_after_release
  end

  # plan-pg-reconnect.md, phase 3: a worker Ractor's connection is
  # terminated between two of its checkouts, as when Postgres restarts
  # while kino's workers sit idle between requests. The second checkout
  # reconnects in that Ractor, on the same connection object.
  def test_a_worker_ractors_next_checkout_reconnects_after_its_backend_is_terminated
    widget = Widget.create(name: "survivor", quantity: 1)
    pids = Ractor::Port.new

    worker = Ractor.new(Widget, DB_NAME, widget[:id], pids) do |model, db_name, id, pids|
      pids << Monk::Persistence::Pg.checkout(db_name, &:backend_pid)
      Ractor.receive # the main Ractor has terminated that backend
      new_pid = Monk::Persistence::Pg.checkout(db_name, &:backend_pid)
      [new_pid, model.find(id)]
    end

    old_pid = pids.receive
    terminate_backend(old_pid)
    worker << :go
    new_pid, found = worker.value

    refute_equal old_pid, new_pid
    assert_equal widget, found
  end
end
