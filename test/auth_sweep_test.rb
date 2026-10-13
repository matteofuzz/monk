require_relative "test_helper"
require "monk/auth"
require "monk/jobs"

# Auth's housekeeping (docs/plan-auth-housekeeping.md decisions 2 and 3,
# Phase 3): sweep! deletes in batches and covers login_requests, and
# Monk::Auth::Sweep runs it as a job.
class AuthSweepTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthTestHelpers
  include JobsTestHelpers

  DB_NAME = :auth_sweep_test_db

  def setup
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
    setup_auth_tables(DB_NAME)
  end

  def teardown
    if postgres_available?
      Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
        drop_jobs_tables(conn)
        drop_auth_tables(conn)
      end
    end
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
    Monk::Auth.reset!
  end

  # More expired rows than one batch: every one goes, and the live ones
  # stay.
  def test_sweep_deletes_more_than_a_batch
    insert_sessions(25, expires_in: -60)
    insert_sessions(3, expires_in: 3600)

    counts = Monk::Auth.sweep!(batch_size: 10)

    assert_equal 25, counts[:sessions]
    assert_equal 3, count_rows(DB_NAME, "sessions")
  end

  # Login requests older than login_request_interval no longer limit
  # anything, so they go; recent ones stay.
  def test_sweep_deletes_login_requests_older_than_the_interval
    Monk::Auth.allow_login_request?("old@example.test")
    Monk::Auth.allow_login_request?("new@example.test")
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec(<<~SQL)
        UPDATE login_requests SET requested_at = now() - interval '61 seconds' WHERE email = 'old@example.test'
      SQL
    end

    counts = Monk::Auth.sweep!

    assert_equal 1, counts[:login_requests]
    refute Monk::Auth.allow_login_request?("new@example.test"), "the recent request still limits"
  end

  def test_the_batch_size_is_a_positive_integer
    assert_raises(ArgumentError) { Monk::Auth.sweep!(batch_size: 0) }
  end

  # --- Monk::Auth::Sweep ---

  def test_the_sweep_job_deletes_expired_rows_and_logs_the_counts
    setup_jobs_tables(DB_NAME)
    Monk::Jobs.configure(db_name: DB_NAME)
    insert_sessions(2, expires_in: -60)

    log = with_log do |dir|
      Monk::Auth::Sweep.enqueue
      assert_equal 1, Monk::Jobs.drain!
      File.read(File.join(dir, "test.log"))
    end

    assert_equal 0, count_rows(DB_NAME, "sessions")
    assert_includes log, "Monk::Auth::Sweep: deleted 2 sessions, 0 login tokens, 0 login requests"
  end

  def test_the_sweep_job_runs_on_the_default_queue
    assert_equal "default", Monk::Auth::Sweep.queue
  end

  private

  def insert_sessions(count, expires_in:)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params(<<~SQL, [count, expires_in])
        INSERT INTO sessions (subject, token_hash, expires_at)
        SELECT 's' || n, md5(random()::text || n), now() + $2::int * interval '1 second'
        FROM generate_series(1, $1::int) AS n
      SQL
    end
  end
end
