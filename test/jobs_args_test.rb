require_relative "test_helper"
require "monk/jobs"

# A job's args are stored as JSON and handed back to #perform in another
# process, so only values that survive that round trip unchanged are
# accepted -- checked when the job is enqueued, not when it runs
# (docs/history/plan-jobs.md Decision 6, Phase 2).
class JobsArgsTest < Minitest::Test
  def test_plain_json_values_are_accepted
    args = ["text", 42, 1.5, true, false, nil, [1, [2, "three"]], { "a" => { "b" => [nil] } }]

    assert_nil Monk::Jobs::Args.check!(args)
  end

  def test_no_args_is_fine
    assert_nil Monk::Jobs::Args.check!([])
  end

  def test_a_symbol_is_rejected_naming_its_position_and_class
    error = assert_raises(Monk::Jobs::InvalidArgumentsError) { Monk::Jobs::Args.check!([1, :pending]) }

    assert_match(/args\[1\]/, error.message)
    assert_match(/Symbol/, error.message)
  end

  def test_a_nested_offender_is_named_by_its_full_path
    args = [{ "user" => { "joined" => Time.now } }]

    error = assert_raises(Monk::Jobs::InvalidArgumentsError) { Monk::Jobs::Args.check!(args) }

    assert_match(/args\[0\]\["user"\]\["joined"\]/, error.message)
    assert_match(/Time/, error.message)
  end

  # JSON turns a Symbol key into a String, so #perform would get back a
  # different Hash than the one enqueued.
  def test_a_symbol_hash_key_is_rejected
    error = assert_raises(Monk::Jobs::InvalidArgumentsError) { Monk::Jobs::Args.check!([{ id: 1 }]) }

    assert_match(/args\[0\]/, error.message)
    assert_match(/:id/, error.message)
  end

  def test_nan_and_infinity_are_not_json
    assert_raises(Monk::Jobs::InvalidArgumentsError) { Monk::Jobs::Args.check!([Float::NAN]) }
    assert_raises(Monk::Jobs::InvalidArgumentsError) { Monk::Jobs::Args.check!([Float::INFINITY]) }
  end

  def test_an_arbitrary_object_is_rejected
    assert_raises(Monk::Jobs::InvalidArgumentsError) { Monk::Jobs::Args.check!([Object.new]) }
  end

  def test_it_is_an_argument_error
    assert_operator Monk::Jobs::InvalidArgumentsError, :<, ArgumentError
  end
end
