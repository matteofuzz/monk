require_relative "test_helper"
require "monk/persistence/pg"

# Named connection pools for short-lived Ractors (docs/history/plan-pg-pool.md).
# Phase 1: declaring a pool, and looking it up before it's started.
class PersistencePoolTest < Minitest::Test
  DB_NAME = :persistence_pool_test_db

  def setup
    Monk::Persistence::Pg.reset!
    Monk::Persistence::Pg.register(DB_NAME, dbname: "unused_until_a_pool_starts")
  end

  def teardown
    Monk::Persistence::Pg.reset!
  end

  def test_a_declared_pool_keeps_its_options_with_defaults_for_the_rest
    Monk::Persistence::Pg.pool(:auth, db: DB_NAME, size: 2)

    config = Monk::Persistence::Pg.pool_config(:auth)

    assert_equal [:auth, DB_NAME, 2, 5, 1000], [config.name, config.db, config.size, config.timeout, config.queue]
    assert Ractor.shareable?(config)
  end

  def test_db_defaults_to_primary
    Monk::Persistence::Pg.register(:primary, dbname: "unused")

    Monk::Persistence::Pg.pool(:auth, size: 2)

    assert_equal :primary, Monk::Persistence::Pg.pool_config(:auth).db
  end

  def test_a_pool_on_an_unregistered_database_is_refused
    error = assert_raises(Monk::UnknownPersistenceError) { Monk::Persistence::Pg.pool(:auth, db: :nope, size: 2) }

    assert_match(/nope/, error.message)
  end

  def test_size_timeout_and_queue_must_be_positive
    { size: 0, timeout: 0, queue: -1 }.each do |option, value|
      error = assert_raises(ArgumentError) { Monk::Persistence::Pg.pool(:auth, db: DB_NAME, option => value) }

      assert_match(/#{option}/, error.message)
    end
    assert_raises(ArgumentError) { Monk::Persistence::Pg.pool(:auth, db: DB_NAME, size: 1.5) }
  end

  def test_an_unknown_option_is_refused
    assert_raises(ArgumentError) { Monk::Persistence::Pg.pool(:auth, db: DB_NAME, ordered: true) }
  end

  def test_declaring_the_same_pool_twice_is_refused
    Monk::Persistence::Pg.pool(:auth, db: DB_NAME, size: 2)

    error = assert_raises(ArgumentError) { Monk::Persistence::Pg.pool(:auth, db: DB_NAME, size: 4) }

    assert_match(/already declared/, error.message)
  end

  def test_looking_up_a_pool_never_declared_says_so
    error = assert_raises(Monk::UnknownPoolError) { Monk::Persistence::Pg.pool(:missing) }

    assert_match(/never declared/, error.message)
    assert_match(/size:/, error.message, "should show how to declare one")
  end

  def test_looking_up_a_declared_pool_before_it_starts_says_so
    Monk::Persistence::Pg.pool(:auth, db: DB_NAME, size: 2)

    error = assert_raises(Monk::PoolNotStartedError) { Monk::Persistence::Pg.pool(:auth) }

    assert_match(/declared but not started in this process/, error.message)
    assert_match(/start_pools!\(:auth\)/, error.message)
  end

  # Pools are looked up from socket Ractors, so after boot the declarations
  # must be readable there: without the freeze, a worker Ractor raises
  # Ractor::IsolationError instead of the pool's own error.
  def test_after_freezing_a_worker_ractor_reads_the_declarations
    Monk::Persistence::Pg.pool(:auth, db: DB_NAME, size: 2)
    Monk::Persistence::Pg.freeze_registry!

    error_class = Ractor.new do
      Monk::Persistence::Pg.pool(:auth)
    rescue StandardError => e
      e.class
    end.value

    assert_equal Monk::PoolNotStartedError, error_class
  end

  def test_reset_forgets_declared_pools
    Monk::Persistence::Pg.pool(:auth, db: DB_NAME, size: 2)

    Monk::Persistence::Pg.reset!

    assert_raises(Monk::UnknownPoolError) { Monk::Persistence::Pg.pool(:auth) }
  end
end
