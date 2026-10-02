require_relative "test_helper"
require "monk/persistence/pg"
require "securerandom"

# Methods the pool's workers run. Module methods named by the call, as a
# real app's models are: a call carries no block.
module PoolTestCalls
  def self.echo(value, keyword:, **rest) = [value, keyword, rest]

  def self.backend_pid(db) = Monk::Persistence::Pg.checkout(db, &:backend_pid)

  def self.raise_argument_error(message) = raise(ArgumentError, message)

  def self.sleep_in_postgres(db, seconds)
    Monk::Persistence::Pg.checkout(db) { |conn| conn.exec_params("SELECT pg_sleep($1)", [seconds]) }
    nil
  end
end

# Named connection pools for short-lived Ractors (docs/history/plan-pg-pool.md).
# Phase 1: declaring a pool, and looking it up before it's started.
class PersistencePoolTest < Minitest::Test
  include PersistenceTestHelpers

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

  # -- Phase 2: starting a pool, and call --

  def test_call_runs_the_method_in_the_pool_with_positional_and_keyword_arguments
    start_pool(:p, size: 2)

    result = Monk::Persistence::Pg.pool(:p).call(PoolTestCalls, :echo, "a", keyword: 1, extra: [2])

    assert_equal ["a", 1, { extra: [2] }], result
  end

  def test_an_exception_from_the_method_reaches_the_caller
    start_pool(:p, size: 1)

    error = assert_raises(ArgumentError) { Monk::Persistence::Pg.pool(:p).call(PoolTestCalls, :raise_argument_error, "nope") }

    assert_equal "nope", error.message
  end

  # The point of a pool: however many Ractors call, the database sees
  # `size` connections, opened at start.
  def test_the_pool_holds_size_connections_however_many_ractors_call_it
    start_pool(:p, size: 2)
    assert_equal 2, connection_count

    callers = Array.new(6) do
      Ractor.new(DB_NAME) do |db|
        pool = Monk::Persistence::Pg.pool(:p)
        Array.new(3) { pool.call(PoolTestCalls, :backend_pid, db) }
      end
    end
    pids = callers.flat_map(&:value).uniq

    assert_operator pids.size, :<=, 2
    assert_equal 2, connection_count
  end

  # Each worker has its own connection, so a pool larger than 1 runs calls
  # side by side: 4 × 0.3 s through 4 workers takes about 0.3 s, not 1.2.
  def test_calls_run_in_parallel_across_workers
    start_pool(:p, size: 4)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    callers = Array.new(4) do
      Ractor.new(DB_NAME) { |db| Monk::Persistence::Pg.pool(:p).call(PoolTestCalls, :sleep_in_postgres, db, 0.3) }
    end
    callers.each(&:value)

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.9
  end

  def test_start_pools_raises_when_the_database_is_unreachable
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(:unreachable, **pg_test_opts, port: 1)
    Monk::Persistence::Pg.pool(:p, db: :unreachable, size: 2)

    error = assert_raises(Monk::PoolStartError) { Monk::Persistence::Pg.start_pools!(:p) }

    assert_match(/:p/, error.message)
    assert_raises(Monk::PoolNotStartedError) { Monk::Persistence::Pg.pool(:p) }
  end

  def test_start_pools_runs_in_the_main_ractor_only
    Monk::Persistence::Pg.pool(:p, db: DB_NAME, size: 1)

    error_class = Ractor.new do
      Monk::Persistence::Pg.start_pools!(:p)
    rescue StandardError => e
      e.class
    end.value

    assert_equal ArgumentError, error_class
  end

  def test_starting_a_started_pool_again_changes_nothing
    start_pool(:p, size: 2)
    handle = Monk::Persistence::Pg.pool(:p)

    Monk::Persistence::Pg.start_pools!(:p)

    assert_same handle, Monk::Persistence::Pg.pool(:p)
    assert_equal 2, connection_count
  end

  def test_reset_stops_the_pool_and_closes_its_connections
    start_pool(:p, size: 2)

    Monk::Persistence::Pg.reset!

    assert_equal 0, connection_count
  end

  private

  # Registers DB_NAME against the test Postgres under an application_name
  # of its own, so connection_count sees only this pool's connections.
  def start_pool(name, size:)
    skip_unless_postgres_available
    Monk::Persistence::Pg.reset!
    @application_name = "monk_pool_test_#{SecureRandom.hex(4)}"
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts, application_name: @application_name)
    Monk::Persistence::Pg.pool(name, db: DB_NAME, size: size)
    Monk::Persistence::Pg.start_pools!(name)
  end

  def connection_count
    conn = PG.connect(**pg_test_opts)
    result = conn.exec_params("SELECT count(*) FROM pg_stat_activity WHERE application_name = $1", [@application_name])
    result.getvalue(0, 0).to_i
  ensure
    conn&.close
  end
end
