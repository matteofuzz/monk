require_relative "test_helper"

class PersistenceModelTest < Minitest::Test
  include PersistenceTestHelpers

  DB_NAME = :persistence_model_test_db

  class Widget < Monk::Persistence::Model
    self.db_name = DB_NAME
    self.table_name = "widgets"
  end

  def setup
    Monk::Persistence.reset!
    skip_unless_postgres_available
    Monk::Persistence.register(DB_NAME, **pg_test_opts)
    Monk::Persistence.checkout(DB_NAME) do |conn|
      conn.exec("DROP TABLE IF EXISTS widgets")
      conn.exec(
        "CREATE TABLE widgets (id SERIAL PRIMARY KEY, name TEXT NOT NULL, quantity INTEGER NOT NULL DEFAULT 0)"
      )
    end
  end

  def teardown
    if postgres_available?
      Monk::Persistence.checkout(DB_NAME) { |conn| conn.exec("DROP TABLE IF EXISTS widgets") }
    end
    Monk::Persistence.reset!
  end

  def test_create_inserts_and_returns_the_row_as_a_symbol_keyed_hash
    row = Widget.create(name: "bolt", quantity: 10)

    assert_kind_of Integer, row[:id]
    assert_equal "bolt", row[:name]
    assert_equal 10, row[:quantity]
  end

  def test_find_returns_the_row_matching_the_id
    created = Widget.create(name: "nut", quantity: 3)

    found = Widget.find(created[:id])

    assert_equal created, found
  end

  def test_find_returns_nil_when_no_row_matches
    assert_nil Widget.find(999_999)
  end

  def test_create_rejects_a_malicious_column_name_rather_than_interpolating_it
    error = assert_raises(PG::Error) { Widget.create(%{name; DROP TABLE widgets;--} => "x") }

    refute_nil error
    row = Widget.create(name: "still here", quantity: 1)
    assert_equal "still here", row[:name]
  end

  def test_concurrent_creates_from_sibling_threads_never_corrupt_a_write
    names = (1..8).map { |i| "widget-#{i}" }

    threads = names.map { |name| Thread.new { Widget.create(name: name, quantity: 1) } }
    rows = threads.map(&:value)

    assert_equal names.sort, rows.map { |r| r[:name] }.sort
    assert_equal names.size, rows.map { |r| r[:id] }.uniq.size
  end

  def test_where_returns_only_rows_matching_all_conditions
    Widget.create(name: "bolt", quantity: 10)
    match = Widget.create(name: "bolt", quantity: 5)
    Widget.create(name: "nut", quantity: 5)

    rows = Widget.where(name: "bolt", quantity: 5)

    assert_equal [match], rows
  end

  def test_where_returns_an_empty_array_when_nothing_matches
    Widget.create(name: "bolt", quantity: 10)

    assert_equal [], Widget.where(name: "does-not-exist")
  end

  def test_where_with_no_conditions_returns_all_rows
    a = Widget.create(name: "bolt", quantity: 10)
    b = Widget.create(name: "nut", quantity: 5)

    rows = Widget.where({})

    assert_equal [a, b].sort_by { |r| r[:id] }, rows.sort_by { |r| r[:id] }
  end

  def test_update_returns_the_updated_row
    created = Widget.create(name: "bolt", quantity: 10)

    updated = Widget.update(created[:id], quantity: 20)

    assert_equal 20, updated[:quantity]
    assert_equal "bolt", updated[:name]
    assert_equal created[:id], updated[:id]
  end

  def test_update_returns_nil_when_the_id_does_not_exist
    assert_nil Widget.update(999_999, quantity: 1)
  end

  def test_delete_removes_the_row_and_returns_true
    created = Widget.create(name: "bolt", quantity: 10)

    assert Widget.delete(created[:id])
    assert_nil Widget.find(created[:id])
  end

  def test_delete_returns_false_when_the_id_does_not_exist
    refute Widget.delete(999_999)
  end
end
