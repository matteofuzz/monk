require_relative "test_helper"
require "monk/persistence/pg"
require "securerandom"

# Methods the pool's workers run. Module methods named by the call, as a
# real app's models are: a call carries no block.
module PoolTestCalls
  def self.echo(value, keyword:, **rest) = [value, keyword, rest]

  def self.backend_pid(db) = Monk::Persistence::Pg.checkout(db, &:backend_pid)

  def self.raise_argument_error(message) = raise(ArgumentError, message)

  class TaggedError < StandardError
    attr_reader :tag

    def initialize(message, tag:)
      super(message)
      @tag = tag
    end
  end

  def self.raise_tagged
    raise ArgumentError, "the cause"
  rescue ArgumentError
    raise TaggedError.new("tagged", tag: "kept")
  end

  def self.insert_duplicate(db)
    Monk::Persistence::Pg.checkout(db) do |conn|
      conn.exec("INSERT INTO pool_test_items (id) VALUES (1) ON CONFLICT DO NOTHING")
      conn.exec("INSERT INTO pool_test_items (id) VALUES (1)")
    end
  end

  def self.insert_duplicate_wrapped(db)
    insert_duplicate(db)
  rescue PG::Error
    raise "saving the item failed"
  end

  def self.record(db, value)
    Monk::Persistence::Pg.checkout(db) { |conn| conn.exec_params("INSERT INTO pool_test_items (id) VALUES ($1)", [value]) }
    nil
  end

  def self.append(db, number)
    Monk::Persistence::Pg.checkout(db) { |conn| conn.exec_params("INSERT INTO pool_test_log (n) VALUES ($1)", [number]) }
    nil
  end

  def self.raw_result(db) = Monk::Persistence::Pg.checkout(db) { |conn| conn.exec("SELECT 1") }

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

  # -- Phase 3: errors and return values --

  def test_an_ordinary_exception_arrives_whole_with_its_cause
    start_pool(:p, size: 1)

    error = assert_raises(PoolTestCalls::TaggedError) { Monk::Persistence::Pg.pool(:p).call(PoolTestCalls, :raise_tagged) }

    assert_equal ["tagged", "kept"], [error.message, error.tag]
    assert_equal [ArgumentError, "the cause"], [error.cause.class, error.cause.message]
  end

  # rescue PG::UniqueViolation must work the same whether the method ran
  # here or in a pool: wrapping the error in a pool error class would
  # silently stop it matching.
  def test_a_pg_error_keeps_its_class_message_and_diagnostic_fields
    start_pool(:p, size: 1)
    with_items_table do
      error = assert_raises(PG::UniqueViolation) do
        Monk::Persistence::Pg.pool(:p).call(PoolTestCalls, :insert_duplicate, DB_NAME)
      end

      assert_match(/duplicate key/, error.message)
      assert_equal "pool_test_items_pkey", error.result.error_field(PG::PG_DIAG_CONSTRAINT_NAME)
      assert_equal "23505", error.result.error_field(PG::PG_DIAG_SQLSTATE)
      assert_match(/duplicate key/, error.result.error_message)
      assert_nil error.connection
      assert_raises(NoMethodError) { error.result.ntuples }
    end
  end

  def test_a_pg_error_as_the_cause_of_another_crosses_too
    start_pool(:p, size: 1)
    with_items_table do
      error = assert_raises(RuntimeError) do
        Monk::Persistence::Pg.pool(:p).call(PoolTestCalls, :insert_duplicate_wrapped, DB_NAME)
      end

      assert_equal "saving the item failed", error.message
      assert_instance_of PG::UniqueViolation, error.cause
      assert_equal "pool_test_items_pkey", error.cause.result.error_field(PG::PG_DIAG_CONSTRAINT_NAME)
    end
  end

  def test_the_backtrace_shows_the_worker_then_the_caller
    start_pool(:p, size: 1)

    error = assert_raises(PoolTestCalls::TaggedError) { Monk::Persistence::Pg.pool(:p).call(PoolTestCalls, :raise_tagged) }

    worker_frame = error.backtrace.index { |line| line.include?("raise_tagged") }
    marker = error.backtrace.index { |line| line.include?("pool :p") }
    caller_frame = error.backtrace.index { |line| line.include?("test_the_backtrace_shows_the_worker_then_the_caller") }
    assert worker_frame && marker && caller_frame, error.backtrace.join("\n")
    assert_operator worker_frame, :<, marker
    assert_operator marker, :<, caller_frame
    refute_empty error.cause.backtrace
  end

  def test_a_return_value_that_cannot_leave_the_pool_names_the_method
    start_pool(:p, size: 1)

    error = assert_raises(Monk::PoolReturnError) { Monk::Persistence::Pg.pool(:p).call(PoolTestCalls, :raw_result, DB_NAME) }

    assert_match(/PoolTestCalls\.raw_result/, error.message)
    assert_match(/PG::Result/, error.message)
  end

  def test_the_worker_keeps_serving_after_errors
    start_pool(:p, size: 1)
    pool = Monk::Persistence::Pg.pool(:p)
    assert_raises(Monk::PoolReturnError) { pool.call(PoolTestCalls, :raw_result, DB_NAME) }
    assert_raises(PoolTestCalls::TaggedError) { pool.call(PoolTestCalls, :raise_tagged) }

    assert_equal ["ok", 1, {}], pool.call(PoolTestCalls, :echo, "ok", keyword: 1)
  end

  # -- Phase 4: timeouts and the queue --

  def test_a_call_raises_once_its_timeout_passes_while_the_method_still_runs
    start_pool(:p, size: 1, timeout: 0.3)
    started = monotonic

    error = assert_raises(Monk::PersistenceTimeoutError) do
      Monk::Persistence::Pg.pool(:p).call(PoolTestCalls, :sleep_in_postgres, DB_NAME, 1.5)
    end

    assert_operator monotonic - started, :<, 1.0
    assert_match(/PoolTestCalls\.sleep_in_postgres/, error.message)
    assert_match(/pool :p/, error.message)
  end

  # Nobody waits for a call that timed out in the queue, so it never runs:
  # a stalled database doesn't build a backlog of work to replay.
  def test_a_call_that_timed_out_while_queued_never_runs
    start_pool(:p, size: 1, timeout: 0.3)
    with_items_table do
      busy = occupy_the_worker(1.0)

      assert_raises(Monk::PersistenceTimeoutError) do
        Monk::Persistence::Pg.pool(:p).call(PoolTestCalls, :record, DB_NAME, 1)
      end
      busy.join
      wait_until_the_worker_is_free

      assert_equal 0, items_count
    end
  end

  def test_a_full_queue_refuses_a_call_at_once
    start_pool(:p, size: 1, timeout: 2, queue: 2)
    busy = occupy_the_worker(1.0)
    queued = Array.new(2) { Thread.new { Monk::Persistence::Pg.pool(:p).call(PoolTestCalls, :echo, "q", keyword: 1) } }
    sleep 0.1 # let both reach the queue
    started = monotonic

    error = assert_raises(Monk::PoolFullError) { Monk::Persistence::Pg.pool(:p).call(PoolTestCalls, :echo, "x", keyword: 1) }

    assert_operator monotonic - started, :<, 0.1
    assert_match(/pool :p/, error.message)
    assert_equal [["q", 1, {}]] * 2, queued.map(&:value)
    busy.join
  end

  # The worker finishes the call whose caller gave up, and its late answer
  # goes nowhere; the next call gets its own answer.
  def test_after_a_timeout_the_worker_serves_the_next_call
    start_pool(:p, size: 1, timeout: 0.2)
    pool = Monk::Persistence::Pg.pool(:p)
    assert_raises(Monk::PersistenceTimeoutError) { pool.call(PoolTestCalls, :sleep_in_postgres, DB_NAME, 0.4) }
    sleep 0.3

    assert_equal ["next", 1, {}], pool.call(PoolTestCalls, :echo, "next", keyword: 1)
  end

  # -- Phase 5: call_async --

  def test_call_async_returns_once_accepted_and_the_method_runs
    start_pool(:p, size: 1)
    with_items_table do
      started = monotonic
      busy = occupy_the_worker(0.5)

      assert_nil Monk::Persistence::Pg.pool(:p).call_async(PoolTestCalls, :record, DB_NAME, 7)

      assert_operator monotonic - started, :<, 0.3, "call_async waited for the busy worker"
      busy.join
      wait_for { items_count == 1 }
    end
  end

  def test_call_async_raises_when_the_queue_is_full
    start_pool(:p, size: 1, queue: 1)
    busy = occupy_the_worker(0.5)
    Monk::Persistence::Pg.pool(:p).call_async(PoolTestCalls, :echo, "queued", keyword: 1)

    assert_raises(Monk::PoolFullError) { Monk::Persistence::Pg.pool(:p).call_async(PoolTestCalls, :echo, "x", keyword: 1) }
    busy.join
  end

  # Nobody waits for an async call, so its failure is logged.
  def test_a_failing_async_call_is_logged
    contents = with_log do |dir|
      with_settings do
        # Boot's order: Settings first, so the log level Monk::Log keeps is
        # frozen and readable from the worker's Ractor.
        Monk::Settings.freeze_registry!
        Monk::Log.freeze_registry!
        start_pool(:p, size: 1)

        Monk::Persistence::Pg.pool(:p).call_async(PoolTestCalls, :raise_argument_error, "lost in the pool")

        wait_for { File.exist?(File.join(dir, "test.log")) && File.read(File.join(dir, "test.log")).include?("lost") }
        File.read(File.join(dir, "test.log"))
      end
    end

    assert_match(/ERROR .*pool :p.*PoolTestCalls\.raise_argument_error.*ArgumentError: lost in the pool/, contents)
  end

  # Order comes from size: one worker runs one sender's calls in the order
  # it made them.
  def test_a_pool_of_one_runs_a_senders_calls_in_order
    start_pool(:p, size: 1)
    with_log_table do
      pool = Monk::Persistence::Pg.pool(:p)
      (1..50).each { |n| pool.call_async(PoolTestCalls, :append, DB_NAME, n) }

      wait_for { log_table_values.size == 50 }
      assert_equal (1..50).to_a, log_table_values
    end
  end

  # A timed-out async call would have nobody to tell: it has no deadline.
  def test_an_async_call_runs_even_after_waiting_longer_than_the_timeout
    start_pool(:p, size: 1, timeout: 0.2)
    with_items_table do
      busy = occupy_the_worker(0.6)
      Monk::Persistence::Pg.pool(:p).call_async(PoolTestCalls, :record, DB_NAME, 9)
      busy.join

      wait_for(within: 3) { items_count == 1 }
    end
  end

  private

  # Registers DB_NAME against the test Postgres under an application_name
  # of its own, so connection_count sees only this pool's connections.
  def start_pool(name, size:, **)
    skip_unless_postgres_available
    Monk::Persistence::Pg.reset!
    @application_name = "monk_pool_test_#{SecureRandom.hex(4)}"
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts, application_name: @application_name)
    Monk::Persistence::Pg.pool(name, db: DB_NAME, size: size, **)
    Monk::Persistence::Pg.start_pools!(name)
  end

  # Keeps the pool's one worker in pg_sleep from a background thread; that
  # call's own timeout is ignored. Returns once the worker is busy.
  def occupy_the_worker(seconds)
    thread = Thread.new do
      Monk::Persistence::Pg.pool(:p).call(PoolTestCalls, :sleep_in_postgres, DB_NAME, seconds)
    rescue Monk::PersistenceTimeoutError
      nil
    end
    sleep 0.1
    thread
  end

  # occupy_the_worker's own call times out long before its pg_sleep ends;
  # a call that gets through means the worker has moved on.
  def wait_until_the_worker_is_free(within: 3)
    deadline = monotonic + within
    begin
      Monk::Persistence::Pg.pool(:p).call(PoolTestCalls, :echo, "free?", keyword: 1)
    rescue Monk::PersistenceTimeoutError
      retry if monotonic < deadline
      raise
    end
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def wait_for(within: 2)
    deadline = monotonic + within
    sleep 0.02 until yield || monotonic > deadline
    assert yield, "condition not met within #{within}s"
  end

  def with_log_table
    conn = PG.connect(**pg_test_opts)
    conn.exec("DROP TABLE IF EXISTS pool_test_log")
    conn.exec("CREATE TABLE pool_test_log (seq bigserial PRIMARY KEY, n int NOT NULL)")
    yield
  ensure
    conn&.exec("DROP TABLE IF EXISTS pool_test_log")
    conn&.close
  end

  def log_table_values
    conn = PG.connect(**pg_test_opts)
    conn.exec("SELECT n FROM pool_test_log ORDER BY seq").column_values(0).map(&:to_i)
  ensure
    conn&.close
  end

  def items_count
    conn = PG.connect(**pg_test_opts)
    conn.exec("SELECT count(*) FROM pool_test_items").getvalue(0, 0).to_i
  ensure
    conn&.close
  end

  def connection_count
    conn = PG.connect(**pg_test_opts)
    result = conn.exec_params("SELECT count(*) FROM pg_stat_activity WHERE application_name = $1", [@application_name])
    result.getvalue(0, 0).to_i
  ensure
    conn&.close
  end

  def with_items_table
    conn = PG.connect(**pg_test_opts)
    conn.exec("DROP TABLE IF EXISTS pool_test_items")
    conn.exec("CREATE TABLE pool_test_items (id int PRIMARY KEY)")
    yield
  ensure
    conn&.exec("DROP TABLE IF EXISTS pool_test_items")
    conn&.close
  end
end
