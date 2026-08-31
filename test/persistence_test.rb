require_relative "test_helper"

class PersistenceTest < Minitest::Test
  include PersistenceTestHelpers

  DB_NAME = :persistence_test_db

  def setup
    Monk::Persistence.reset!
  end

  def teardown
    Monk::Persistence.reset!
  end

  def test_lookup_raises_a_precise_error_for_an_unregistered_name
    error = assert_raises(Monk::UnknownPersistenceError) { Monk::Persistence[:nope] }

    assert_match(/nope/, error.message)
  end

  def test_register_then_lookup_returns_a_connection
    skip_unless_postgres_available
    Monk::Persistence.register(DB_NAME, **pg_test_opts)

    assert_instance_of PG::Connection, Monk::Persistence[DB_NAME]
  end

  def test_lookup_memoizes_the_connection_within_the_same_ractor
    skip_unless_postgres_available
    Monk::Persistence.register(DB_NAME, **pg_test_opts)

    first = Monk::Persistence[DB_NAME]
    second = Monk::Persistence[DB_NAME]

    assert_same first, second
  end

  def test_checkout_yields_a_usable_connection
    skip_unless_postgres_available
    Monk::Persistence.register(DB_NAME, **pg_test_opts)

    value = Monk::Persistence.checkout(DB_NAME) { |conn| conn.exec("SELECT 1 AS one").getvalue(0, 0) }

    assert_equal 1, value
  end

  def test_checkout_serializes_concurrent_access_and_times_out
    skip_unless_postgres_available
    Monk::Persistence.register(DB_NAME, **pg_test_opts)

    holder = Thread.new { Monk::Persistence.checkout(DB_NAME) { sleep 0.3 } }
    sleep 0.05 # let the holder acquire the slot first

    error = assert_raises(Monk::PersistenceTimeoutError) do
      Monk::Persistence.checkout(DB_NAME, timeout: 0.1) { flunk "should not run while the slot is held" }
    end
    assert_match(/persistence_test_db/, error.message)

    holder.join
  end

  def test_checkout_releases_the_slot_after_the_holder_finishes
    skip_unless_postgres_available
    Monk::Persistence.register(DB_NAME, **pg_test_opts)

    Monk::Persistence.checkout(DB_NAME) { |conn| conn.exec("SELECT 1") }

    value = Monk::Persistence.checkout(DB_NAME, timeout: 0.1) { |conn| conn.exec("SELECT 2 AS two").getvalue(0, 0) }
    assert_equal 2, value
  end
end
