require_relative "test_helper"
require "monk/jobs"

# Declaring recurring tasks (docs/history/plan-scheduled-jobs.md decision 2,
# Phase 2): checked when declared, so a mistake fails at boot; frozen with
# the rest of Monk::Jobs' registry. No database.
module JobsRecurringTest
  class PurgeSessions < Monk::Job
    def self.perform; end
  end

  class SendDigest < Monk::Job
    queue "mailers"

    def self.perform(kind); end
  end

  NotAJob = Class.new
end

class JobsRecurringDeclarationTest < Minitest::Test
  Purge = JobsRecurringTest::PurgeSessions
  Digest = JobsRecurringTest::SendDigest

  def setup
    Monk::Jobs.reset!
  end

  def teardown
    Monk::Jobs.reset!
  end

  def test_a_declared_task_is_listed_with_its_parsed_schedule
    Monk::Jobs.recurring "purge_sessions", Purge, cron: "0 3 * * *"

    task = Monk::Jobs.recurring_tasks.fetch(0)
    assert_equal "purge_sessions", task.key
    assert_same Purge, task.job_class
    assert_equal "0 3 * * *", task.cron.expression
    assert_equal [], task.args
    refute task.skip_if_pending
  end

  def test_args_and_skip_if_pending
    Monk::Jobs.recurring "weekly_digest", Digest, cron: "0 9 * * 1", args: ["weekly"], skip_if_pending: true

    task = Monk::Jobs.recurring_tasks.fetch(0)
    assert_equal ["weekly"], task.args
    assert task.skip_if_pending
  end

  # One job class, several schedules: the key tells them apart.
  def test_one_job_class_can_have_several_tasks
    Monk::Jobs.recurring "daily_digest", Digest, cron: "@daily", args: ["daily"]
    Monk::Jobs.recurring "weekly_digest", Digest, cron: "@weekly", args: ["weekly"]

    assert_equal %w[daily_digest weekly_digest], Monk::Jobs.recurring_tasks.map(&:key)
  end

  def test_no_tasks_declared
    assert_equal [], Monk::Jobs.recurring_tasks
  end

  def test_the_key_must_be_a_non_empty_string
    [nil, "", :purge, 1].each do |key|
      error = assert_raises(ArgumentError, key.inspect) { Monk::Jobs.recurring key, Purge, cron: "@daily" }
      assert_match(/key/, error.message)
    end
  end

  def test_a_key_is_declared_once
    Monk::Jobs.recurring "purge_sessions", Purge, cron: "0 3 * * *"

    error = assert_raises(ArgumentError) { Monk::Jobs.recurring "purge_sessions", Digest, cron: "@daily" }

    assert_match(/"purge_sessions" is already declared/, error.message)
  end

  def test_the_job_class_must_be_a_named_monk_job
    [JobsRecurringTest::NotAJob, "JobsRecurringTest::PurgeSessions"].each do |job_class|
      error = assert_raises(ArgumentError) { Monk::Jobs.recurring "purge", job_class, cron: "@daily" }
      assert_match(/Monk::Jobs\.recurring needs a Monk::Job subclass/, error.message)
    end

    error = assert_raises(ArgumentError) { Monk::Jobs.recurring "purge", Class.new(Monk::Job), cron: "@daily" }
    assert_match(/has no name/, error.message)
  end

  def test_a_bad_cron_fails_at_declaration
    assert_raises(Monk::Jobs::InvalidCronError) { Monk::Jobs.recurring "purge", Purge, cron: "0 0 30 2 *" }
    assert_raises(Monk::Jobs::InvalidCronError) { Monk::Jobs.recurring "purge", Purge, cron: "every day" }
  end

  def test_args_must_survive_json
    assert_raises(Monk::Jobs::InvalidArgumentsError) do
      Monk::Jobs.recurring "digest", Digest, cron: "@daily", args: [:weekly]
    end
  end

  def test_skip_if_pending_is_true_or_false
    error = assert_raises(ArgumentError) do
      Monk::Jobs.recurring "digest", Digest, cron: "@daily", args: ["x"], skip_if_pending: "yes"
    end
    assert_match(/skip_if_pending/, error.message)
  end

  # A failed declaration leaves nothing behind: fixing it and declaring
  # again works.
  def test_a_rejected_task_is_not_recorded
    assert_raises(Monk::Jobs::InvalidCronError) { Monk::Jobs.recurring "purge", Purge, cron: "nope" }
    Monk::Jobs.recurring "purge", Purge, cron: "@daily"

    assert_equal ["purge"], Monk::Jobs.recurring_tasks.map(&:key)
  end

  # Args are kept as declared, not as the caller's object: changing the
  # Array afterwards doesn't change the task.
  def test_args_are_copied
    args = ["weekly"]
    Monk::Jobs.recurring "digest", Digest, cron: "@daily", args: args
    args << "extra"

    assert_equal ["weekly"], Monk::Jobs.recurring_tasks.fetch(0).args
  end

  def test_frozen_with_the_registry_and_readable_from_a_ractor
    Monk::Jobs.recurring "weekly_digest", Digest, cron: "0 9 * * 1", args: [{ "kind" => "weekly" }]
    Monk.freeze!

    tasks = Monk::Jobs.recurring_tasks
    assert Ractor.shareable?(tasks)
    keys = Ractor.new { Monk::Jobs.recurring_tasks.map { |task| [task.key, task.job_class.queue] } }.value
    assert_equal [["weekly_digest", "mailers"]], keys
  end

  def test_declaring_after_the_registry_is_frozen_is_an_error
    Monk.freeze!

    error = assert_raises(Monk::Jobs::RegistryFrozenError) { Monk::Jobs.recurring "purge", Purge, cron: "@daily" }

    assert_match(%r{config/recurring\.rb}, error.message)
  end

  def test_reset_forgets_the_tasks
    Monk::Jobs.recurring "purge", Purge, cron: "@daily"
    Monk::Jobs.reset!

    assert_equal [], Monk::Jobs.recurring_tasks
  end
end
