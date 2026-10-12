require_relative "test_helper"
require "json"
require "monk/jobs"
require "monk/persistence/pg"

# The Postgres adapter's fire_recurring (docs/plan-scheduled-jobs.md
# decisions 5-8, Phase 3): one statement that moves a recurring task's
# checkpoint and enqueues its job, against the real schema.
module JobsPgRecurringJobs
  class SendDigest < Monk::Job
    queue "mailers"
    priority(-5)
    max_attempts 3
  end
end

class JobsPgRecurringTest < Minitest::Test
  include PersistenceTestHelpers
  include JobsTestHelpers

  DB_NAME = :jobs_pg_recurring_test_db
  PROCESS_ID = 1
  CRON = "0 * * * *".freeze
  # Whole hours safely in the past, so the database clock has reached
  # them without passing clock:.
  T0 = Time.utc(2026, 1, 5, 9)
  T1 = T0 + 3600
  T2 = T1 + 3600

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

  # --- a new task: decision 6 ---

  def test_a_new_task_is_initialized_without_enqueueing
    firing = fire(T0)

    assert_equal :initialized, firing.result
    assert_nil firing.job_id
    assert_nil firing.previous_checkpoint
    assert_equal 0, count_rows(DB_NAME, "monk_jobs")

    task = task_row("digest")
    assert_equal CRON, task["cron"]
    assert_equal T0, task["last_occurrence_at"]
    assert_nil task["last_job_id"]
  end

  # --- a later occurrence ---

  def test_a_later_occurrence_enqueues_the_job_with_its_class_settings
    fire(T0)

    firing = fire(T1)

    assert_equal :enqueued, firing.result
    assert_equal T0, firing.previous_checkpoint
    job = job_row(DB_NAME, firing.job_id)
    assert_equal "available", job["state"]
    assert_equal "mailers", job["queue"]
    assert_equal(-5, job["priority"])
    assert_equal 3, job["max_attempts"]
    assert_equal "JobsPgRecurringJobs::SendDigest", job["job_class"]
    assert_equal ["weekly", { "n" => 1 }], JSON.parse(job["args"])

    task = task_row("digest")
    assert_equal T1, task["last_occurrence_at"]
    assert_equal firing.job_id, task["last_job_id"]
  end

  # Decision 6: after downtime only the latest occurrence fires, and the
  # old checkpoint comes back for the "skipped N occurrences" log line.
  def test_a_task_several_occurrences_behind_fires_once
    fire(T0)

    firing = fire(T0 + (5 * 3600))

    assert_equal :enqueued, firing.result
    assert_equal T0, firing.previous_checkpoint
    assert_equal 1, count_rows(DB_NAME, "monk_jobs")
  end

  # --- another process got there first ---

  def test_the_same_occurrence_twice_is_already_handled
    fire(T0)
    fire(T1)

    firing = fire(T1)

    assert_equal :already_handled, firing.result
    assert_nil firing.job_id
    assert_equal 1, count_rows(DB_NAME, "monk_jobs")
  end

  # A process a minute behind asks about an occurrence older than the
  # checkpoint: nothing moves backwards.
  def test_an_older_occurrence_is_already_handled
    fire(T0)
    fire(T2)

    assert_equal :already_handled, fire(T1).result
    assert_equal T2, task_row("digest")["last_occurrence_at"]
    assert_equal 1, count_rows(DB_NAME, "monk_jobs")
  end

  # --- the database clock decides: decision 5 ---

  def test_an_occurrence_in_the_future_is_not_due
    future = Time.now.utc + 3600

    assert_equal :not_due, fire(future).result
    assert_nil task_row("digest")
  end

  def test_a_future_occurrence_is_not_due_for_an_existing_task_either
    fire(T0)

    assert_equal :not_due, fire(Time.now.utc + 3600).result
    assert_equal T0, task_row("digest")["last_occurrence_at"]
    assert_equal 0, count_rows(DB_NAME, "monk_jobs")
  end

  # run_scheduler!(at:)'s clock (decision 11) stands in for now().
  def test_a_clock_makes_a_future_occurrence_due
    future = Time.now.utc + (2 * 3600)
    fire(future - 3600, clock: future)

    assert_equal :enqueued, fire(future, clock: future).result
  end

  def test_a_clock_before_the_occurrence_makes_it_not_due
    assert_equal :not_due, fire(T1, clock: T0).result
  end

  # --- a changed cron expression: decision 8 ---

  def test_a_changed_cron_resets_the_checkpoint_without_enqueueing
    fire(T0)
    fire(T1)

    firing = fire(T2, cron: "30 * * * *")

    assert_equal :reinitialized, firing.result
    assert_nil firing.job_id
    task = task_row("digest")
    assert_equal "30 * * * *", task["cron"]
    assert_equal T2, task["last_occurrence_at"]
    assert_nil task["last_job_id"]
    assert_equal 1, count_rows(DB_NAME, "monk_jobs")
  end

  def test_after_a_reset_the_next_occurrence_fires
    fire(T0)
    fire(T1, cron: "30 * * * *")

    assert_equal :enqueued, fire(T2, cron: "30 * * * *").result
  end

  # --- skip_if_pending: decision 7 ---

  def test_skip_if_pending_skips_while_the_previous_job_is_available
    fire(T0, skip_if_pending: true)
    previous = fire(T1, skip_if_pending: true).job_id

    firing = fire(T2, skip_if_pending: true)

    assert_equal :skipped_pending, firing.result
    assert_nil firing.job_id
    task = task_row("digest")
    assert_equal T2, task["last_occurrence_at"], "the occurrence is used up, not delayed"
    assert_equal previous, task["last_job_id"]
    assert_equal 1, count_rows(DB_NAME, "monk_jobs")
  end

  def test_skip_if_pending_skips_while_the_previous_job_is_running
    fire(T0, skip_if_pending: true)
    previous = fire(T1, skip_if_pending: true).job_id
    set_state(previous, "running")

    assert_equal :skipped_pending, fire(T2, skip_if_pending: true).result
  end

  # Scheduled for a retry: not done yet.
  def test_skip_if_pending_skips_while_the_previous_job_waits_for_a_retry
    fire(T0, skip_if_pending: true)
    previous = fire(T1, skip_if_pending: true).job_id
    set_state(previous, "scheduled")

    assert_equal :skipped_pending, fire(T2, skip_if_pending: true).result
  end

  # A failed run doesn't block the task for good.
  def test_skip_if_pending_enqueues_when_the_previous_job_failed
    fire(T0, skip_if_pending: true)
    previous = fire(T1, skip_if_pending: true).job_id
    set_state(previous, "failed")

    firing = fire(T2, skip_if_pending: true)

    assert_equal :enqueued, firing.result
    assert_equal firing.job_id, task_row("digest")["last_job_id"]
  end

  # Finished jobs are deleted, so a dangling last_job_id means done.
  def test_skip_if_pending_enqueues_when_the_previous_job_finished
    fire(T0, skip_if_pending: true)
    previous = fire(T1, skip_if_pending: true).job_id
    Monk::Persistence::Pg.checkout(DB_NAME) { |c| c.exec_params("DELETE FROM monk_jobs WHERE id = $1", [previous]) }

    assert_equal :enqueued, fire(T2, skip_if_pending: true).result
  end

  def test_without_skip_if_pending_a_pending_job_doesnt_stop_the_next
    fire(T0)
    fire(T1)

    assert_equal :enqueued, fire(T2).result
    assert_equal 2, count_rows(DB_NAME, "monk_jobs")
  end

  # --- clear! ---

  def test_clear_empties_the_recurring_tasks
    fire(T0)

    Monk::Jobs.clear!

    assert_equal 0, count_rows(DB_NAME, "monk_recurring_tasks")
  end

  private

  def fire(occurrence, cron: CRON, skip_if_pending: false, clock: nil)
    job = JobsPgRecurringJobs::SendDigest
    Monk::Jobs.adapter.fire_recurring(
      key: "digest", cron: cron, occurrence: occurrence, skip_if_pending: skip_if_pending,
      job_class: job.name, queue: job.queue, priority: job.priority, max_attempts: job.max_attempts,
      args: JSON.generate(["weekly", { "n" => 1 }]), clock: clock,
    )
  end

  def task_row(key)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("SELECT * FROM monk_recurring_tasks WHERE key = $1", [key]).first
    end
  end

  def set_state(id, state)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("UPDATE monk_jobs SET state = $2 WHERE id = $1", [id, state])
    end
  end
end
