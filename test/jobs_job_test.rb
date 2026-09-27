require_relative "test_helper"
require "monk/jobs"

# Monk::Job and Monk::Jobs' class registry (docs/history/plan-jobs.md
# Phase 2, Seam A): no database. Job classes are ordinary named
# constants, as in an app -- a Monk::Job subclass is recorded when it's
# defined, and there is no undoing that, so these live at the top of the
# file rather than being built per test.
module JobsJobTest
  class SendReceipt < Monk::Job
    def self.perform(order_id, email)
      "receipt #{order_id} to #{email}"
    end
  end

  class MailerJob < Monk::Job
    queue "mailers"
    priority(-5)
    max_attempts 3
    timeout 30
  end

  class WelcomeEmail < MailerJob
    def self.perform(user_id)
      "welcome #{user_id}"
    end
  end

  class NoPerform < Monk::Job
  end
end

class JobsRegistryTest < Minitest::Test
  def setup
    Monk::Jobs.reset!
  end

  def teardown
    Monk::Jobs.reset!
  end

  def test_a_subclass_is_found_by_its_class_name_once_frozen
    Monk::Jobs.freeze_registry!

    assert_same JobsJobTest::SendReceipt, Monk::Jobs.lookup("JobsJobTest::SendReceipt")
  end

  def test_freezing_is_one_of_monks_boot_hooks
    Monk.freeze!

    assert_same JobsJobTest::WelcomeEmail, Monk::Jobs.lookup("JobsJobTest::WelcomeEmail")
  end

  def test_freezing_twice_is_harmless
    Monk::Jobs.freeze_registry!
    Monk::Jobs.freeze_registry!

    assert_same JobsJobTest::SendReceipt, Monk::Jobs.lookup("JobsJobTest::SendReceipt")
  end

  def test_looking_up_before_freezing_names_the_fix
    error = assert_raises(Monk::Jobs::NotFrozenError) { Monk::Jobs.lookup("JobsJobTest::SendReceipt") }

    assert_match(/Monk\.freeze!/, error.message)
  end

  def test_an_unknown_name_is_an_error_naming_it
    Monk::Jobs.freeze_registry!

    error = assert_raises(Monk::Jobs::UnknownJobError) { Monk::Jobs.lookup("Nope::Missing") }

    assert_match(/Nope::Missing/, error.message)
  end

  # Only Monk::Job subclasses can be run from a name found in the
  # database -- never Object.const_get on whatever string a row holds.
  def test_a_class_that_isnt_a_job_is_unknown_even_if_it_exists
    Monk::Jobs.freeze_registry!

    assert_raises(Monk::Jobs::UnknownJobError) { Monk::Jobs.lookup("File") }
  end

  def test_monk_job_itself_is_not_a_runnable_job
    Monk::Jobs.freeze_registry!

    assert_raises(Monk::Jobs::UnknownJobError) { Monk::Jobs.lookup("Monk::Job") }
  end

  def test_a_worker_ractor_resolves_and_runs_a_job_once_frozen
    Monk.freeze!

    result = Ractor.new do
      job = Monk::Jobs.lookup("JobsJobTest::SendReceipt")
      [job.perform(42, "a@b.com"), job.queue, job.priority, job.max_attempts]
    end.value

    assert_equal ["receipt 42 to a@b.com", "default", 0, 5], result
  end

  def test_a_worker_ractor_reads_inherited_settings
    Monk.freeze!

    result = Ractor.new do
      job = Monk::Jobs.lookup("JobsJobTest::WelcomeEmail")
      [job.perform(7), job.queue, job.priority, job.max_attempts]
    end.value

    assert_equal ["welcome 7", "mailers", -5, 3], result
  end

  # ADR 0003 posture: a Monk error that names the fix, not an opaque
  # Ractor::IsolationError from reading an unfrozen module ivar.
  def test_a_worker_ractor_looking_up_before_freezing_gets_the_monk_error
    error = assert_raises(Ractor::RemoteError) do
      Ractor.new do
        # The raise is the point of this test; keep it out of the test output.
        Thread.current.report_on_exception = false
        Monk::Jobs.lookup("JobsJobTest::SendReceipt")
      end.value
    end

    assert_instance_of Monk::Jobs::NotFrozenError, error.cause
  end
end

class JobsSettingsTest < Minitest::Test
  def test_defaults
    assert_equal "default", JobsJobTest::SendReceipt.queue
    assert_equal 0, JobsJobTest::SendReceipt.priority
    assert_equal 5, JobsJobTest::SendReceipt.max_attempts
  end

  def test_settings_are_inherited_by_subclasses
    assert_equal "mailers", JobsJobTest::WelcomeEmail.queue
    assert_equal(-5, JobsJobTest::WelcomeEmail.priority)
    assert_equal 3, JobsJobTest::WelcomeEmail.max_attempts
  end

  def test_a_queue_name_is_frozen_so_worker_ractors_can_read_it
    assert Ractor.shareable?(JobsJobTest::MailerJob.queue)
  end

  def test_an_empty_or_non_string_queue_is_rejected
    job = Class.new(Monk::Job)

    assert_raises(ArgumentError) { job.queue "" }
    assert_raises(ArgumentError) { job.queue :mailers }
  end

  # monk_jobs.priority and max_attempts are SMALLINT columns.
  def test_priority_must_fit_the_column
    job = Class.new(Monk::Job)

    assert_raises(ArgumentError) { job.priority 40_000 }
    assert_raises(ArgumentError) { job.priority 1.5 }
  end

  def test_max_attempts_must_be_at_least_one
    job = Class.new(Monk::Job)

    assert_raises(ArgumentError) { job.max_attempts 0 }
    assert_raises(ArgumentError) { job.max_attempts 40_000 }
  end

  def test_no_timeout_by_default
    assert_nil JobsJobTest::SendReceipt.timeout
  end

  def test_timeout_is_set_and_inherited
    assert_equal 30, JobsJobTest::MailerJob.timeout
    assert_equal 30, JobsJobTest::WelcomeEmail.timeout
  end

  def test_timeout_must_be_a_positive_number_of_seconds
    job = Class.new(Monk::Job)

    assert_raises(ArgumentError) { job.timeout 0 }
    assert_raises(ArgumentError) { job.timeout(-1) }
    assert_raises(ArgumentError) { job.timeout "30" }
    assert_equal 0.5, job.timeout(0.5)
  end

  def test_a_job_without_perform_says_so
    error = assert_raises(NotImplementedError) { JobsJobTest::NoPerform.perform }

    assert_match(/JobsJobTest::NoPerform/, error.message)
  end
end
