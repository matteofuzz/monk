require_relative "test_helper"
require "monk/jobs"
require "monk/persistence/pg"

# Failures, retries and scheduled jobs on the Postgres adapter
# (docs/history/plan-jobs.md Phase 4, Seam B).
module JobsPgFailuresJobs
  class Flaky < Monk::Job
    max_attempts 2
  end
end

class JobsPgFailuresTest < Minitest::Test
  include PersistenceTestHelpers
  include JobsTestHelpers

  DB_NAME = :jobs_pg_failures_test_db
  PROCESS_ID = 1

  def setup
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
    skip_unless_postgres_available

    setup_jobs_tables(DB_NAME)
    Monk::Jobs.configure(db_name: DB_NAME)
  end

  def teardown
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_jobs_tables(conn) } if postgres_available?
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
  end

  # --- fail ---

  def test_a_failure_with_attempts_left_is_scheduled_to_retry
    id = claimed_job

    assert_equal :scheduled, adapter.fail(id, PROCESS_ID, error: "RuntimeError: boom", retry_in: 30)

    job = job_row(id)
    assert_equal "scheduled", job["state"]
    assert_in_delta 30, job["seconds_until_due"], 2
    assert_nil job["locked_by"]
    assert_nil job["locked_at"]
    assert_equal "RuntimeError: boom", job["last_error"]
  end

  def test_a_failure_on_the_last_attempt_fails_the_job_for_good
    id = claimed_job
    adapter.fail(id, PROCESS_ID, error: "first", retry_in: 0)
    make_due(id)
    adapter.stage_due
    adapter.claim("default", PROCESS_ID)

    assert_equal :failed, adapter.fail(id, PROCESS_ID, error: "second", retry_in: 30)

    job = job_row(id)
    assert_equal "failed", job["state"]
    assert_equal 2, job["attempts"]
    assert_equal "second", job["last_error"]
    assert_nil job["locked_by"]
  end

  # For what's never worth retrying: an unknown job class, an invalid
  # message.
  def test_a_failure_without_retry_in_fails_the_job_straight_away
    id = claimed_job

    assert_equal :failed, adapter.fail(id, PROCESS_ID, error: "unknown job class", retry_in: nil)

    assert_equal "failed", job_row(id)["state"]
  end

  def test_a_failure_reported_by_a_process_that_no_longer_holds_the_job_changes_nothing
    id = claimed_job

    assert_nil adapter.fail(id, 2, error: "late", retry_in: 30)

    job = job_row(id)
    assert_equal "running", job["state"]
    assert_nil job["last_error"]
  end

  def test_a_failed_job_is_never_claimed_or_staged
    id = claimed_job
    adapter.fail(id, PROCESS_ID, error: "gone", retry_in: nil)

    assert_equal 0, adapter.stage_due
    assert_nil adapter.claim("default", PROCESS_ID)
  end

  # The whole retry path by the clock rather than by moving run_at by hand.
  def test_a_retried_job_comes_back_after_retry_in_with_its_attempts_counted
    id = claimed_job
    adapter.fail(id, PROCESS_ID, error: "boom", retry_in: 0.3)
    assert_nil adapter.claim("default", PROCESS_ID)

    sleep 0.4
    adapter.stage_due

    claim = adapter.claim("default", PROCESS_ID)
    assert_equal [id, 2], [claim.id, claim.attempts]
  end

  # --- stage_due ---

  def test_a_scheduled_job_is_claimable_only_once_due_and_staged
    id = JobsPgFailuresJobs::Flaky.enqueue(1, wait: 3600)
    assert_nil adapter.claim("default", PROCESS_ID)

    make_due(id)
    assert_nil adapter.claim("default", PROCESS_ID), "due but not staged yet"

    assert_equal 1, adapter.stage_due
    assert_equal id, adapter.claim("default", PROCESS_ID).id
  end

  def test_stage_due_leaves_jobs_that_arent_due_yet
    due = JobsPgFailuresJobs::Flaky.enqueue(1, wait: 3600)
    later = JobsPgFailuresJobs::Flaky.enqueue(2, wait: 3600)
    make_due(due)

    assert_equal 1, adapter.stage_due

    assert_equal "available", job_row(due)["state"]
    assert_equal "scheduled", job_row(later)["state"]
  end

  def test_stage_due_moves_at_most_limit_jobs_per_call
    ids = Array.new(5) { |i| JobsPgFailuresJobs::Flaky.enqueue(i, wait: 3600) }
    ids.each { |id| make_due(id) }

    assert_equal 3, adapter.stage_due(3)
    assert_equal 2, adapter.stage_due(3)
    assert_equal 0, adapter.stage_due(3)
  end

  # Every job process runs the stager, so two may stage at once.
  def test_concurrent_stagers_move_each_due_job_exactly_once
    ids = Array.new(200) { |i| JobsPgFailuresJobs::Flaky.enqueue(i, wait: 3600) }
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec("UPDATE monk_jobs SET run_at = now() - interval '1 second'") }
    Monk.freeze!

    staged = Array.new(4) do
      Ractor.new(adapter) do |adapter|
        total = 0
        while (moved = adapter.stage_due(10)).positive?
          total += moved
        end
        total
      end
    end.sum(&:value)

    assert_equal ids.size, staged
    assert_equal ids.size, count_in_state("available")
  end

  # --- retry_failed / discard_failed ---

  def test_retry_failed_makes_a_failed_job_available_again_with_fresh_attempts
    id = failed_job

    assert Monk::Jobs.retry_failed(id)

    job = job_row(id)
    assert_equal "available", job["state"]
    assert_equal 0, job["attempts"]
    assert_equal id, adapter.claim("default", PROCESS_ID).id
  end

  def test_a_retried_failed_job_queues_behind_jobs_already_waiting
    failed = failed_job
    waiting = JobsPgFailuresJobs::Flaky.enqueue(2)

    Monk::Jobs.retry_failed(failed)

    assert_equal [waiting, failed], Array.new(2) { adapter.claim("default", PROCESS_ID).id }
  end

  def test_retry_failed_leaves_a_job_that_hasnt_failed_alone
    id = claimed_job

    refute Monk::Jobs.retry_failed(id)

    assert_equal "running", job_row(id)["state"]
  end

  def test_discard_failed_deletes_a_failed_job_and_its_payload
    id = failed_job

    assert Monk::Jobs.discard_failed(id)

    assert_equal 0, count_rows(DB_NAME, "monk_jobs")
    assert_equal 0, count_rows(DB_NAME, "monk_job_payloads")
  end

  def test_discard_failed_leaves_a_job_that_hasnt_failed_alone
    id = JobsPgFailuresJobs::Flaky.enqueue(1)

    refute Monk::Jobs.discard_failed(id)

    assert_equal 1, count_rows(DB_NAME, "monk_jobs")
  end

  private

  def adapter
    Monk::Jobs.adapter
  end

  def claimed_job
    id = JobsPgFailuresJobs::Flaky.enqueue(1)
    adapter.claim("default", PROCESS_ID)
    id
  end

  def failed_job
    id = claimed_job
    adapter.fail(id, PROCESS_ID, error: "boom", retry_in: nil)
    id
  end

  def make_due(id)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("UPDATE monk_jobs SET run_at = now() - interval '1 second' WHERE id = $1", [id])
    end
  end

  def job_row(id)
    super(DB_NAME, id)
  end

  def count_in_state(state)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("SELECT count(*) FROM monk_jobs WHERE state = $1", [state]).getvalue(0, 0)
    end
  end
end
