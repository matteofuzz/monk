require_relative "test_helper"
require "monk/jobs"
require "monk/persistence/pg"

# Monk::Jobs.run_scheduler!(at:), for an app's own tests of its recurring
# tasks: one scheduler pass as if the clock read `at`, then drain!
# (docs/plan-scheduled-jobs.md decision 11, Phase 5).
module JobsRunSchedulerJobs
  SEEN = [] # rubocop:disable Style/MutableConstant

  class Digest < Monk::Job
    def self.perform(kind)
      SEEN << kind
    end
  end
end

class JobsRunSchedulerTest < Minitest::Test
  include PersistenceTestHelpers
  include JobsTestHelpers

  DB_NAME = :jobs_run_scheduler_test_db
  MONDAY_9AM = Time.utc(2026, 10, 12, 9)

  def setup
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
    JobsRunSchedulerJobs::SEEN.clear
    skip_unless_postgres_available

    setup_jobs_tables(DB_NAME)
    Monk::Jobs.configure(db_name: DB_NAME)
    Monk::Jobs.recurring "weekly_digest", JobsRunSchedulerJobs::Digest, cron: "0 9 * * 1", args: ["weekly"]
  end

  def teardown
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_jobs_tables(conn) } if postgres_available?
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
  end

  # What an app's test does: the first pass sets the checkpoint, the
  # second, at the next occurrence, enqueues; drain! runs the job.
  def test_declare_initialize_advance_drain
    assert_equal({ "weekly_digest" => :initialized }, Monk::Jobs.run_scheduler!(at: MONDAY_9AM - 60))
    assert_equal({ "weekly_digest" => :enqueued }, Monk::Jobs.run_scheduler!(at: MONDAY_9AM))

    assert_equal 1, Monk::Jobs.drain!(in_ractor: false)
    assert_equal ["weekly"], JobsRunSchedulerJobs::SEEN
  end

  def test_between_occurrences_nothing_is_enqueued
    Monk::Jobs.run_scheduler!(at: MONDAY_9AM)

    assert_equal({ "weekly_digest" => :already_handled }, Monk::Jobs.run_scheduler!(at: MONDAY_9AM + (3 * 86_400)))
    assert_equal 0, Monk::Jobs.drain!
  end

  # at: stands in for the database clock too, so an occurrence after
  # today's date is due.
  def test_at_in_the_future_is_due
    next_monday = Time.now.utc + (8 * 86_400)
    Monk::Jobs.run_scheduler!(at: next_monday - (7 * 86_400))

    assert_equal({ "weekly_digest" => :enqueued }, Monk::Jobs.run_scheduler!(at: next_monday))
  end

  # Each call asks the database again: nothing is remembered between calls
  # the way a bin/jobs process remembers between ticks.
  def test_calls_dont_remember_each_other
    Monk::Jobs.run_scheduler!(at: MONDAY_9AM - 60)
    Monk::Jobs.run_scheduler!(at: MONDAY_9AM)

    assert_equal({ "weekly_digest" => :already_handled }, Monk::Jobs.run_scheduler!(at: MONDAY_9AM))
  end

  # clear! between tests forgets checkpoints, so the next test starts by
  # initializing again.
  def test_clear_forgets_the_checkpoints
    Monk::Jobs.run_scheduler!(at: MONDAY_9AM)
    Monk::Jobs.clear!

    assert_equal({ "weekly_digest" => :initialized }, Monk::Jobs.run_scheduler!(at: MONDAY_9AM + (7 * 86_400)))
  end

  def test_at_defaults_to_now
    assert_equal({ "weekly_digest" => :initialized }, Monk::Jobs.run_scheduler!)
  end

  def test_run_scheduler_refuses_outside_the_test_environment
    with_settings do
      with_env("MONK_ENV", "production") do
        error = assert_raises(Monk::Jobs::RunSchedulerOutsideTestsError) { Monk::Jobs.run_scheduler!(at: MONDAY_9AM) }
        assert_match(/MONK_ENV=test/, error.message)
      end
    end
    assert_equal 0, count_rows(DB_NAME, "monk_recurring_tasks")
  end

  # drain! only runs what's queued; it never fires schedules itself.
  def test_drain_never_fires_schedules
    Monk::Jobs.run_scheduler!(at: MONDAY_9AM - 60)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec("UPDATE monk_recurring_tasks SET last_occurrence_at = now() - interval '30 days'")
    end

    assert_equal 0, Monk::Jobs.drain!
  end
end
