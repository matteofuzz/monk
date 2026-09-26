require_relative "test_helper"
require "monk/jobs"

# The retry policy both adapters share (docs/history/plan-jobs.md
# Decision 10), and how a failure is written into last_error.
class JobsRetryPolicyTest < Minitest::Test
  def test_backoff_grows_with_the_number_of_attempts
    assert_equal([16, 31, 96, 271, 640], (1..5).map { |attempts| Monk::Jobs.backoff(attempts) })
  end

  def test_describe_error_has_the_class_the_message_and_the_first_backtrace_lines
    error = raise_and_rescue(ArgumentError, "bad order", Array.new(20) { |i| "app/jobs/x.rb:#{i}" })

    text = Monk::Jobs.describe_error(error)

    assert text.start_with?("ArgumentError: bad order\n")
    assert_includes text, "app/jobs/x.rb:0"
    assert_includes text, "app/jobs/x.rb:9"
    refute_includes text, "app/jobs/x.rb:10"
  end

  def test_describe_error_is_capped_in_length
    error = raise_and_rescue(RuntimeError, "x" * 20_000, [])

    assert_operator Monk::Jobs.describe_error(error).length, :<=, Monk::Jobs::MAX_ERROR_LENGTH
  end

  def test_describe_error_copes_with_an_error_that_was_never_raised
    assert_equal "RuntimeError: not raised", Monk::Jobs.describe_error(RuntimeError.new("not raised"))
  end

  private

  def raise_and_rescue(klass, message, backtrace)
    raise klass, message, backtrace
  rescue klass => e
    e
  end
end
