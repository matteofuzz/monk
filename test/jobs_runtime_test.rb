require_relative "test_helper"
require "monk/jobs"
require "monk/jobs/runtime"
require "monk/persistence/pg"

# The job process's runtime in one process (docs/history/plan-jobs.md
# Phase 6, Seam C): the supervisor in this Ractor, run on a thread here so
# the test can stop it, and real worker Ractors claiming from the real
# queue. Jobs record what they did in a results table the test reads.
module JobsRuntimeJobs
  DB = :jobs_runtime_test_db

  # Not a StandardError, like a failure deep in a C extension: it gets
  # past a job's own rescue and ends the worker Ractor.
  class Fatal < Exception # rubocop:disable Lint/InheritException
  end

  def self.record(value)
    Monk::Persistence::Pg.checkout(DB) do |conn|
      conn.exec_params("INSERT INTO jobs_runtime_results (value) VALUES ($1)", [value])
    end
  end

  class Record < Monk::Job
    def self.perform(value) = JobsRuntimeJobs.record(value)
  end

  class Slow < Monk::Job
    def self.perform(seconds, value)
      sleep seconds
      JobsRuntimeJobs.record(value)
    end
  end

  class Flaky < Monk::Job
    def self.perform(*) = raise(ArgumentError, "flaky")
  end

  class NoPerform < Monk::Job
  end

  class SlowQuery < Monk::Job
    timeout 0.5

    def self.perform
      Monk::Persistence::Pg.checkout(DB) { |conn| conn.exec("SELECT pg_sleep(5)") }
    end
  end

  class RejectedForGood < Monk::Job
    never_retry KeyError

    def self.perform(error) = raise(error == "subclass" ? IndexError.new("no") : KeyError, "no such key")
  end

  class RetriesOtherErrors < Monk::Job
    never_retry KeyError

    def self.perform = raise(ArgumentError, "might work next time")
  end

  class Crashes < Monk::Job
    def self.perform = raise(Fatal, "the worker Ractor goes down with this")
  end

  # Runs to the end, then (first time only) leaves the worker's
  # connection unable to write, so the finish that follows fails the way
  # it would if the database went away right after the job ran. Killing
  # the backend no longer does it: checkout reconnects a dropped
  # connection (plan-pg-reconnect.md). A read-only session does, and the
  # worker that replaces the dead one opens a fresh session.
  class CantFinish < Monk::Job
    def self.perform
      first_run = Monk::Persistence::Pg.checkout(DB) do |conn|
        conn.exec("SELECT count(*) FROM jobs_runtime_results WHERE value = 'ran'").getvalue(0, 0).zero?
      end
      JobsRuntimeJobs.record("ran")
      return unless first_run

      Monk::Persistence::Pg.checkout(DB) { |conn| conn.exec("SET default_transaction_read_only = on") }
    end
  end
end

class JobsRuntimeTest < Minitest::Test
  include PersistenceTestHelpers
  include JobsTestHelpers

  DB_NAME = JobsRuntimeJobs::DB
  FAST = {
    workers: 2, poll_interval: 0.05, tick_interval: 0.05, heartbeat_interval: 0.2,
    process_timeout: 1.0, shutdown_timeout: 2.0,
  }.freeze

  def setup
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
    skip_unless_postgres_available

    setup_jobs_tables(DB_NAME)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      drop_table_if_exists(conn, "jobs_runtime_results")
      conn.exec("CREATE TABLE jobs_runtime_results (value TEXT NOT NULL)")
    end
    Monk::Jobs.configure(db_name: DB_NAME)
  end

  def teardown
    stop_runtime
    if postgres_available?
      Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
        drop_jobs_tables(conn)
        drop_table_if_exists(conn, "jobs_runtime_results")
      end
    end
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
  end

  def test_runs_enqueued_jobs_as_a_registered_process
    5.times { |i| JobsRuntimeJobs::Record.enqueue("job #{i}") }

    start_runtime

    wait_until { results.size == 5 }
    assert_equal (0..4).map { |i| "job #{i}" }, results.sort
    assert_equal 1, count_rows(DB_NAME, "monk_processes")
    wait_until { count_rows(DB_NAME, "monk_jobs").zero? }
  end

  def test_stopping_deletes_the_process_row
    start_runtime
    wait_until { count_rows(DB_NAME, "monk_processes") == 1 }

    stop_runtime

    assert_equal 0, count_rows(DB_NAME, "monk_processes")
  end

  def test_a_failing_job_is_scheduled_to_retry_and_the_worker_keeps_going
    flaky = JobsRuntimeJobs::Flaky.enqueue
    JobsRuntimeJobs::Record.enqueue("after")

    start_runtime(workers: 1)

    wait_until { results.include?("after") }
    job = job_row(DB_NAME, flaky)
    assert_equal "scheduled", job["state"]
    assert_in_delta Monk::Jobs.backoff(1), job["seconds_until_due"], 3
    assert_match(/\AArgumentError: flaky/, job["last_error"])
  end

  def test_a_job_whose_class_isnt_known_fails_without_retrying
    id = Monk::Jobs.adapter.enqueue(
      job_class: "Nope::Gone", queue: "default", priority: 0, max_attempts: 5, args: "[]",
    )

    start_runtime

    wait_until { job_row(DB_NAME, id)["state"] == "failed" }
    assert_match(/UnknownJobError/, job_row(DB_NAME, id)["last_error"])
  end

  def test_an_error_listed_in_never_retry_fails_the_job_at_once
    id = JobsRuntimeJobs::RejectedForGood.enqueue("listed")

    start_runtime

    wait_until { job_row(DB_NAME, id)["state"] == "failed" }
    assert_equal 1, job_row(DB_NAME, id)["attempts"]
    assert_match(/\AKeyError: no such key/, job_row(DB_NAME, id)["last_error"])
  end

  # Matched like rescue: IndexError's subclass KeyError is listed, not
  # IndexError itself, so this one is retried.
  def test_never_retry_matches_subclasses_only_not_parents
    id = JobsRuntimeJobs::RejectedForGood.enqueue("subclass")

    start_runtime

    wait_until { job_row(DB_NAME, id)["state"] == "scheduled" }
  end

  def test_errors_not_listed_in_never_retry_are_still_retried
    id = JobsRuntimeJobs::RetriesOtherErrors.enqueue

    start_runtime

    wait_until { job_row(DB_NAME, id)["state"] == "scheduled" }
  end

  def test_a_job_without_perform_fails_without_retrying
    id = JobsRuntimeJobs::NoPerform.enqueue

    start_runtime

    wait_until { job_row(DB_NAME, id)["state"] == "failed" }
  end

  # Phase 0.3: a timed-out query keeps running on the server, and without
  # a connection reset the worker's next query would wait for it.
  def test_a_timed_out_job_is_retried_and_its_worker_moves_on_at_once
    slow = JobsRuntimeJobs::SlowQuery.enqueue
    JobsRuntimeJobs::Record.enqueue("next")
    started = monotonic

    start_runtime(workers: 1)

    wait_until { results.include?("next") }
    assert_operator monotonic - started, :<, 3, "the next job waited for the abandoned query"
    job = job_row(DB_NAME, slow)
    assert_equal "scheduled", job["state"]
    assert_match(/Timeout::Error/, job["last_error"])
  end

  # A non-StandardError ends the worker Ractor; the job is still failed
  # first, not left running inside a live process nothing would prune.
  def test_a_worker_that_dies_is_respawned_and_its_job_isnt_left_running
    crashes = JobsRuntimeJobs::Crashes.enqueue
    JobsRuntimeJobs::Record.enqueue("after the crash")

    start_runtime(workers: 1)

    wait_until { results.include?("after the crash") }
    job = job_row(DB_NAME, crashes)
    assert_equal "scheduled", job["state"]
    assert_match(/JobsRuntimeJobs::Fatal/, job["last_error"])
  end

  # The job ran, but its finish never reached the database: the worker
  # dies, and the supervisor releases the job it was holding rather than
  # leaving it running inside a live process that nothing would prune.
  def test_a_job_held_by_a_worker_that_died_is_released_and_run_again
    JobsRuntimeJobs::CantFinish.enqueue

    start_runtime(workers: 1)

    wait_until { count_rows(DB_NAME, "monk_jobs").zero? }
    assert_equal %w[ran ran], results
  end

  def test_workers_get_fresh_connections_after_theirs_are_killed
    start_runtime
    wait_until { worker_backends.size >= 2 }

    doomed = worker_backends
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      doomed.each { |pid| conn.exec_params("SELECT pg_terminate_backend($1)", [pid]) }
    end
    JobsRuntimeJobs::Record.enqueue("after the connections died")

    wait_until { results.include?("after the connections died") }
    assert_equal ["after the connections died"], results
  end

  def test_scheduled_jobs_run_once_due
    JobsRuntimeJobs::Record.enqueue("later", wait: 0.3)

    start_runtime

    wait_until { results.include?("later") }
  end

  def test_a_dead_processs_jobs_are_released_and_run
    dead = Monk::Jobs.adapter.register_process(hostname: "gone", pid: 1)
    id = JobsRuntimeJobs::Record.enqueue("orphan")
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params(
        "UPDATE monk_jobs SET state = 'running', locked_by = $2, locked_at = now(), attempts = 1 WHERE id = $1",
        [id, dead],
      )
      conn.exec_params(
        "UPDATE monk_processes SET last_heartbeat_at = now() - interval '1 hour' WHERE id = $1", [dead],
      )
    end

    start_runtime

    wait_until { results.include?("orphan") }
  end

  def test_stop_lets_a_job_in_flight_finish
    id = JobsRuntimeJobs::Slow.enqueue(0.5, "finished in time")
    start_runtime
    wait_until { job_row(DB_NAME, id)&.fetch("state") == "running" }

    stop_runtime

    assert_includes results, "finished in time"
    assert_equal 0, count_rows(DB_NAME, "monk_jobs")
  end

  # Past shutdown_timeout the job is released for another process to run,
  # while the worker still finishes it here: at-least-once (Decision 4).
  def test_a_job_still_running_after_shutdown_timeout_is_released
    id = JobsRuntimeJobs::Slow.enqueue(1.5, "finished late")
    start_runtime(shutdown_timeout: 0.2)
    wait_until { job_row(DB_NAME, id)&.fetch("state") == "running" }

    started = monotonic
    stop_runtime
    assert_operator monotonic - started, :<, 1.2, "stop waited past shutdown_timeout"

    assert_equal "available", job_row(DB_NAME, id)["state"]
    wait_until { results.include?("finished late") }
    assert_equal "available", job_row(DB_NAME, id)["state"], "the late finish mustn't delete a released job"
  end

  def test_invalid_settings_are_rejected
    assert_raises(ArgumentError) { Monk::Jobs::Runtime.new(workers: 0) }
    assert_raises(ArgumentError) { Monk::Jobs::Runtime.new(queues: []) }
    assert_raises(ArgumentError) { Monk::Jobs::Runtime.new(queues: [""]) }
    assert_raises(ArgumentError) { Monk::Jobs::Runtime.new(poll_interval: 0) }
  end

  private

  def start_runtime(**overrides)
    @runtime = Monk::Jobs::Runtime.new(**FAST, **overrides)
    @runtime_thread = Thread.new { @runtime.run(trap_signals: false) }
    @runtime_thread.report_on_exception = true
  end

  def stop_runtime
    return unless @runtime

    @runtime.stop
    @runtime_thread.join(10) or flunk("the runtime didn't stop")
    @runtime = nil
  end

  def results
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec("SELECT value FROM jobs_runtime_results").map { |row| row["value"] }
    end
  end

  # Backends polling the queue, other than this Ractor's own connection
  # (which the supervisor, running on a thread here, shares).
  def worker_backends
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec(<<~SQL).map { |row| row["pid"] }
        SELECT pid FROM pg_stat_activity
        WHERE datname = current_database() AND pid <> pg_backend_pid() AND query LIKE '%monk_jobs%'
      SQL
    end
  end

  def wait_until(timeout: 5)
    deadline = monotonic + timeout
    until yield
      flunk("condition not met within #{timeout}s") if monotonic > deadline
      sleep 0.02
    end
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
