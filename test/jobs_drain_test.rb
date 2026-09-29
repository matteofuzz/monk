require_relative "test_helper"
require "monk/jobs"
require "monk/persistence/pg"

# Monk::Jobs.drain! and clear!, for an app's own tests: enqueue, drain!,
# assert, clear! (docs/history/plan-jobs.md Phase 5), against the real
# Postgres queue an app's tests use.
module JobsDrainJobs
  # Deliberately not shareable: a job reading it works in the main
  # Ractor and fails in a worker Ractor, as it would in bin/jobs.
  SEEN = [] # rubocop:disable Style/MutableConstant

  class Receipt < Monk::Job
    def self.perform(*) = nil
  end

  class Chain < Monk::Job
    def self.perform(remaining)
      Chain.enqueue(remaining - 1) if remaining.positive?
    end
  end

  class Boom < Monk::Job
    def self.perform(*) = raise(ArgumentError, "boom")
  end

  class RecordsInAGlobal < Monk::Job
    def self.perform(value)
      SEEN << value
    end
  end

  class NoPerform < Monk::Job
  end
end

class JobsDrainTest < Minitest::Test
  include PersistenceTestHelpers
  include JobsTestHelpers

  DB_NAME = :jobs_drain_test_db

  def setup
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
    JobsDrainJobs::SEEN.clear
    skip_unless_postgres_available

    setup_jobs_tables(DB_NAME)
    Monk::Jobs.configure(db_name: DB_NAME)
  end

  def teardown
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_jobs_tables(conn) } if postgres_available?
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
  end

  # --- drain! ---

  def test_drain_runs_every_due_job_including_ones_jobs_enqueue
    JobsDrainJobs::Chain.enqueue(2)
    JobsDrainJobs::Receipt.enqueue

    assert_equal 4, Monk::Jobs.drain!
    assert_equal 0, Monk::Jobs.drain!
    assert_equal 0, count_rows(DB_NAME, "monk_jobs")
  end

  def test_drain_runs_a_job_thats_due_but_not_yet_staged
    JobsDrainJobs::Receipt.enqueue(wait: 0.2)
    sleep 0.3

    assert_equal 1, Monk::Jobs.drain!
  end

  def test_drain_leaves_jobs_that_arent_due
    JobsDrainJobs::Receipt.enqueue(wait: 3600)

    assert_equal 0, Monk::Jobs.drain!
    assert_equal 1, count_rows(DB_NAME, "monk_jobs")
  end

  def test_drain_reraises_a_jobs_own_error_and_fails_the_job
    id = JobsDrainJobs::Boom.enqueue(1)

    error = assert_raises(ArgumentError) { Monk::Jobs.drain! }

    assert_equal "boom", error.message
    assert_equal "failed", job_row(DB_NAME, id)["state"]
    assert_match(/\AArgumentError: boom/, job_row(DB_NAME, id)["last_error"])
  end

  # drain! runs each job in a throwaway Ractor by default, so a test
  # catches a job that only works in the main Ractor.
  def test_drain_runs_jobs_in_a_ractor_so_ractor_unsafe_jobs_fail_in_tests
    JobsDrainJobs::RecordsInAGlobal.enqueue("x")

    assert_raises(Ractor::IsolationError) { Monk::Jobs.drain! }
    assert_empty JobsDrainJobs::SEEN
  end

  def test_drain_in_the_calling_ractor_when_asked
    JobsDrainJobs::RecordsInAGlobal.enqueue("x")
    JobsDrainJobs::RecordsInAGlobal.enqueue("y")

    assert_equal 2, Monk::Jobs.drain!(in_ractor: false)
    assert_equal %w[x y], JobsDrainJobs::SEEN
  end

  # NotImplementedError is a ScriptError, not a StandardError.
  def test_drain_fails_a_job_without_perform_rather_than_leaving_it_running
    id = JobsDrainJobs::NoPerform.enqueue

    assert_raises(NotImplementedError) { Monk::Jobs.drain! }
    assert_equal "failed", job_row(DB_NAME, id)["state"]
  end

  def test_drain_fails_a_job_whose_class_isnt_known
    id = Monk::Jobs.adapter.enqueue(
      job_class: "Nope::Gone", queue: "default", priority: 0, max_attempts: 5, args: "[]",
    )

    assert_raises(Monk::Jobs::UnknownJobError) { Monk::Jobs.drain! }
    assert_equal "failed", job_row(DB_NAME, id)["state"]
  end

  # --- clear! ---

  def test_clear_empties_the_queue_failed_jobs_included
    JobsDrainJobs::Receipt.enqueue
    JobsDrainJobs::Receipt.enqueue(wait: 3600)
    JobsDrainJobs::Boom.enqueue
    assert_raises(ArgumentError) { Monk::Jobs.drain! }

    Monk::Jobs.clear!

    assert_equal 0, count_rows(DB_NAME, "monk_jobs")
    assert_equal 0, count_rows(DB_NAME, "monk_job_payloads")
  end

  def test_clear_refuses_outside_the_test_environment
    JobsDrainJobs::Receipt.enqueue

    with_settings do
      with_env("MONK_ENV", "production") do
        error = assert_raises(Monk::Jobs::ClearOutsideTestsError) { Monk::Jobs.clear! }
        assert_match(/MONK_ENV=test/, error.message)
      end
    end
    assert_equal 1, count_rows(DB_NAME, "monk_jobs")
  end
end
