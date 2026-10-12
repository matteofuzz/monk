require_relative "test_helper"
require "json"
require "monk/jobs"
require "monk/jobs/scheduler"
require "monk/persistence/pg"

# The scheduler (docs/plan-scheduled-jobs.md decisions 5-7, Phase 4): one
# pass per supervisor tick over the declared tasks, against the real
# schema. Each Scheduler stands for one job process; `now` is passed in,
# so the occurrences are fixed hours in the past, already reached by the
# database clock.
module JobsSchedulerJobs
  class Purge < Monk::Job
  end

  class Digest < Monk::Job
    queue "mailers"
  end
end

class JobsSchedulerTest < Minitest::Test
  include PersistenceTestHelpers
  include JobsTestHelpers

  DB_NAME = :jobs_scheduler_test_db
  T0 = Time.utc(2026, 1, 5, 9)

  # Counts what reaches the database, to show the per-process Hash keeps
  # it to one call per occurrence.
  class CountingAdapter
    attr_reader :calls

    def initialize(adapter)
      @adapter = adapter
      @calls = 0
    end

    def fire_recurring(**)
      @calls += 1
      @adapter.fire_recurring(**)
    end
  end

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

  def test_a_new_task_is_initialized_then_fires_at_its_next_occurrence
    Monk::Jobs.recurring "purge", JobsSchedulerJobs::Purge, cron: "0 * * * *"
    scheduler = new_scheduler

    scheduler.run(T0 + 600)
    assert_equal 0, count_rows(DB_NAME, "monk_jobs"), "a new task doesn't fire on deploy"

    scheduler.run(T0 + 3600 + 5)
    assert_equal [["JobsSchedulerJobs::Purge", "[]"]], jobs
  end

  def test_each_task_fires_with_its_own_class_and_args
    Monk::Jobs.recurring "purge", JobsSchedulerJobs::Purge, cron: "0 * * * *"
    Monk::Jobs.recurring "digest", JobsSchedulerJobs::Digest, cron: "0 * * * *", args: ["hourly"]
    scheduler = new_scheduler
    scheduler.run(T0)

    scheduler.run(T0 + 3600)

    assert_equal [["JobsSchedulerJobs::Digest", '["hourly"]'], ["JobsSchedulerJobs::Purge", "[]"]], jobs.sort
  end

  # Two job processes, each ticking: one job per occurrence.
  def test_two_processes_enqueue_each_occurrence_once
    Monk::Jobs.recurring "purge", JobsSchedulerJobs::Purge, cron: "0 * * * *"
    first = new_scheduler
    second = new_scheduler

    [T0, T0 + 3600, T0 + 3600 + 30, T0 + 7200].each do |now|
      first.run(now)
      second.run(now)
    end

    assert_equal 2, count_rows(DB_NAME, "monk_jobs")
  end

  # Decision 5.2: ticking every second within one occurrence reaches the
  # database once.
  def test_an_occurrence_already_handled_here_isnt_asked_about_again
    Monk::Jobs.recurring "purge", JobsSchedulerJobs::Purge, cron: "0 * * * *"
    adapter = CountingAdapter.new(Monk::Jobs.adapter)
    scheduler = new_scheduler(adapter)

    60.times { |s| scheduler.run(T0 + s) }
    60.times { |s| scheduler.run(T0 + 3600 + s) }

    assert_equal 2, adapter.calls
  end

  # Decision 5.4: not_due is asked again, since by the database clock it
  # hasn't happened yet.
  def test_an_occurrence_not_yet_due_is_asked_about_again
    Monk::Jobs.recurring "purge", JobsSchedulerJobs::Purge, cron: "* * * * *"
    adapter = CountingAdapter.new(Monk::Jobs.adapter)
    scheduler = new_scheduler(adapter)
    ahead = Time.now.utc + 3600

    3.times { scheduler.run(ahead) }

    assert_equal 3, adapter.calls
  end

  # Decision 6.
  def test_catching_up_logs_how_many_occurrences_were_skipped
    Monk::Jobs.recurring "purge", JobsSchedulerJobs::Purge, cron: "0 * * * *"
    scheduler = new_scheduler

    log = with_log do |dir|
      scheduler.run(T0)
      scheduler.run(T0 + (4 * 3600))
      File.read(File.join(dir, "test.log"))
    end

    assert_equal 1, count_rows(DB_NAME, "monk_jobs")
    assert_includes log, "purge: caught up from 2026-01-05T09:00:00Z, skipped 3 occurrences"
  end

  def test_skipping_while_pending_is_logged
    Monk::Jobs.recurring "purge", JobsSchedulerJobs::Purge, cron: "0 * * * *", skip_if_pending: true
    scheduler = new_scheduler

    log = with_log do |dir|
      scheduler.run(T0)
      scheduler.run(T0 + 3600)
      scheduler.run(T0 + 7200)
      File.read(File.join(dir, "test.log"))
    end

    assert_equal 1, count_rows(DB_NAME, "monk_jobs")
    assert_match(/INFO .*purge: skipped 2026-01-05T11:00:00Z, the previous run is still pending/, log)
  end

  def test_no_tasks_no_queries
    adapter = CountingAdapter.new(Monk::Jobs.adapter)

    new_scheduler(adapter).run(T0)

    assert_equal 0, adapter.calls
  end

  private

  def new_scheduler(adapter = Monk::Jobs.adapter)
    Monk::Jobs::Scheduler.new(adapter, Monk::Jobs.recurring_tasks)
  end

  def jobs
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec("SELECT job_class, args::text AS args FROM monk_job_payloads").map { |r| [r["job_class"], r["args"]] }
    end
  end
end
