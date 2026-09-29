require_relative "test_helper"
require "json"
require "monk/jobs"
require "monk/persistence/pg"

# The Postgres adapter's enqueue, claim and finish (docs/history/plan-jobs.md
# Phase 3, Seam B), against the real schema from Phase 1's migration.
module JobsPgAdapterJobs
  class SendReceipt < Monk::Job
    def self.perform(order_id) = order_id
  end

  class Urgent < Monk::Job
    priority(-10)
  end

  class Mailer < Monk::Job
    queue "mailers"
    max_attempts 2
  end
end

class JobsPgAdapterTest < Minitest::Test
  include PersistenceTestHelpers
  include JobsTestHelpers

  DB_NAME = :jobs_pg_adapter_test_db
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

  # --- enqueue ---

  def test_enqueue_stores_an_available_job_with_its_class_settings_and_args
    id = JobsPgAdapterJobs::Mailer.enqueue(42, { "note" => "é" })

    job = job_row(id)
    assert_equal "available", job["state"]
    assert_equal "mailers", job["queue"]
    assert_equal 0, job["priority"]
    assert_equal 2, job["max_attempts"]
    assert_equal 0, job["attempts"]
    assert_equal "JobsPgAdapterJobs::Mailer", job["job_class"]
    assert_equal [42, { "note" => "é" }], JSON.parse(job["args"])
  end

  def test_enqueue_with_no_args_stores_an_empty_array
    id = JobsPgAdapterJobs::SendReceipt.enqueue

    assert_equal [], JSON.parse(job_row(id)["args"])
  end

  def test_enqueue_with_wait_schedules_the_job_that_far_ahead_by_the_database_clock
    id = JobsPgAdapterJobs::SendReceipt.enqueue(1, wait: 60)

    job = job_row(id)
    assert_equal "scheduled", job["state"]
    assert_in_delta 60, job["seconds_until_due"], 2
  end

  def test_enqueue_at_a_future_time_schedules_it
    id = JobsPgAdapterJobs::SendReceipt.enqueue(1, at: Time.now + 3600)

    assert_equal "scheduled", job_row(id)["state"]
  end

  def test_enqueue_at_a_past_time_is_available_straight_away
    id = JobsPgAdapterJobs::SendReceipt.enqueue(1, at: Time.now - 3600)

    assert_equal "available", job_row(id)["state"]
  end

  def test_wait_and_at_together_is_an_error
    assert_raises(ArgumentError) { JobsPgAdapterJobs::SendReceipt.enqueue(1, wait: 5, at: Time.now) }
  end

  def test_a_negative_wait_is_an_error
    assert_raises(ArgumentError) { JobsPgAdapterJobs::SendReceipt.enqueue(1, wait: -1) }
  end

  def test_invalid_args_raise_and_store_nothing
    assert_raises(Monk::Jobs::InvalidArgumentsError) { JobsPgAdapterJobs::SendReceipt.enqueue(Time.now) }

    assert_equal 0, count_jobs
  end

  def test_an_anonymous_job_class_cant_be_enqueued
    error = assert_raises(ArgumentError) { Monk::Jobs.enqueue(Class.new(Monk::Job), 1) }

    assert_match(/name/, error.message)
  end

  def test_only_a_monk_job_subclass_can_be_enqueued
    assert_raises(ArgumentError) { Monk::Jobs.enqueue(String, 1) }
    assert_raises(ArgumentError) { Monk::Jobs.enqueue(Monk::Job, 1) }
  end

  # Decision 9: on the caller's own connection, inside the caller's own
  # transaction, the job commits or rolls back with the app's data.
  def test_enqueue_on_the_callers_connection_rolls_back_with_its_transaction
    assert_raises(PG::Error) do
      Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
        conn.transaction do
          JobsPgAdapterJobs::SendReceipt.enqueue(1, conn: conn)
          raise PG::Error, "the app's own write failed"
        end
      end
    end

    assert_equal 0, count_jobs
  end

  def test_enqueue_on_the_callers_connection_commits_with_its_transaction
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.transaction { JobsPgAdapterJobs::SendReceipt.enqueue(1, conn: conn) }
    end

    assert_equal 1, count_jobs
  end

  def test_enqueue_before_configure_names_the_fix
    Monk::Jobs.reset!

    error = assert_raises(Monk::Jobs::NotConfiguredError) { JobsPgAdapterJobs::SendReceipt.enqueue(1) }

    assert_match(/Monk::Jobs\.configure/, error.message)
  end

  # Where it matters: a route handler runs in one of the server's worker
  # Ractors.
  def test_enqueue_from_a_worker_ractor_after_boot
    Monk.freeze!

    id = Ractor.new { JobsPgAdapterJobs::SendReceipt.enqueue(7) }.value

    assert_equal "JobsPgAdapterJobs::SendReceipt", job_row(id)["job_class"]
  end

  # --- claim ---

  def test_claim_returns_the_job_and_marks_it_running_for_this_process
    id = JobsPgAdapterJobs::SendReceipt.enqueue(42, "x")

    claim = adapter.claim("default", PROCESS_ID)

    assert_equal id, claim.id
    assert_equal "JobsPgAdapterJobs::SendReceipt", claim.job_class
    assert_equal [42, "x"], claim.args
    assert_equal 1, claim.attempts
    job = job_row(id)
    assert_equal "running", job["state"]
    assert_equal PROCESS_ID, job["locked_by"]
    refute_nil job["locked_at"]
  end

  def test_claim_returns_nil_when_nothing_is_available
    assert_nil adapter.claim("default", PROCESS_ID)
  end

  def test_claim_only_looks_at_the_queue_asked_for
    JobsPgAdapterJobs::Mailer.enqueue(1)

    assert_nil adapter.claim("default", PROCESS_ID)
    refute_nil adapter.claim("mailers", PROCESS_ID)
  end

  def test_scheduled_and_failed_jobs_are_never_claimed
    JobsPgAdapterJobs::SendReceipt.enqueue(1, wait: 3600)
    failed = JobsPgAdapterJobs::SendReceipt.enqueue(2)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("UPDATE monk_jobs SET state = 'failed' WHERE id = $1", [failed])
    end

    assert_nil adapter.claim("default", PROCESS_ID)
  end

  def test_a_running_job_is_not_claimed_again
    JobsPgAdapterJobs::SendReceipt.enqueue(1)
    adapter.claim("default", PROCESS_ID)

    assert_nil adapter.claim("default", 2)
  end

  def test_a_lower_priority_number_is_claimed_first_then_oldest_first
    first_normal = JobsPgAdapterJobs::SendReceipt.enqueue(1)
    second_normal = JobsPgAdapterJobs::SendReceipt.enqueue(2)
    urgent = JobsPgAdapterJobs::Urgent.enqueue(3)

    claimed = Array.new(3) { adapter.claim("default", PROCESS_ID).id }

    assert_equal [urgent, first_normal, second_normal], claimed
  end

  def test_concurrent_claims_from_worker_ractors_never_share_a_job
    ids = Array.new(200) { |i| JobsPgAdapterJobs::SendReceipt.enqueue(i) }
    Monk.freeze!

    claimed = Array.new(8) do |worker|
      Ractor.new(adapter, worker) do |adapter, worker|
        mine = []
        while (claim = adapter.claim("default", worker))
          mine << claim.id
        end
        mine
      end
    end.flat_map(&:value)

    assert_equal ids.sort, claimed.sort
  end

  # --- finish ---

  def test_finish_deletes_the_job_and_its_payload
    id = JobsPgAdapterJobs::SendReceipt.enqueue(1)
    adapter.claim("default", PROCESS_ID)

    assert adapter.finish(id, PROCESS_ID)

    assert_equal 0, count_jobs
    assert_equal 0, count_rows(DB_NAME, "monk_job_payloads")
  end

  # A job pruned from a dead process and claimed again elsewhere must not
  # be deleted by the first worker finishing late.
  def test_finish_by_a_process_that_no_longer_holds_the_job_leaves_it_alone
    id = JobsPgAdapterJobs::SendReceipt.enqueue(1)
    adapter.claim("default", PROCESS_ID)

    refute adapter.finish(id, 2)

    assert_equal "running", job_row(id)["state"]
  end

  private

  def adapter
    Monk::Jobs.adapter
  end

  def job_row(id)
    super(DB_NAME, id)
  end

  def count_jobs
    count_rows(DB_NAME, "monk_jobs")
  end
end
