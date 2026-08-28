require_relative "test_helper"

class StateRactorTest < Minitest::Test
  # #update's block must be built where self is shareable (e.g. a Class, as
  # in real app-definition scope) -- Ractor.make_shareable always requires a
  # Proc's lexical self to be shareable, regardless of what the block body
  # touches. A bare block written inline in this test method (self = the
  # test instance) would fail for that reason, so this mirrors real usage.
  def test_reads_and_updates_state_synchronously
    result = Class.new.class_exec do
      counter = Monk::StateRactor.new(0)
      initial = counter.value
      updated = counter.update { |v| v + 1 }
      final = counter.value
      [initial, updated, final]
    end

    assert_equal [0, 1, 1], result
  end

  def test_instance_is_shareable
    counter = Monk::StateRactor.new(0)

    assert Ractor.shareable?(counter)
  end

  def test_several_sequential_updates_never_lose_a_mutation
    result = Class.new.class_exec do
      counter = Monk::StateRactor.new(0)
      10.times { counter.update { |v| v + 1 } }
      counter.value
    end

    assert_equal 10, result
  end

  def test_update_raises_precise_error_when_block_is_not_shareable
    counter = Monk::StateRactor.new(0)

    error = assert_raises(Monk::UnshareableBlockError) { counter.update { |v| v + 1 } }

    assert_match(/StateRactor#update/, error.message)
  end
end
