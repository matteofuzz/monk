require_relative "test_helper"

class PersistenceBootTest < Minitest::Test
  # Model.subclasses is a permanent, process-global registry by design (a
  # real app's Model classes live for the whole process). Anonymous
  # subclasses created in these tests would otherwise leak into it forever
  # -- and a genuinely-broken one (see the Mutex test below) would then
  # poison every *other* test file's .freeze! call for the rest of the
  # suite. Snapshot/restore around each test so nothing here outlives it.
  def setup
    @subclasses_before = Monk::Persistence::Model.subclasses.dup
  end

  def teardown
    Monk::Persistence::Model.subclasses.replace(@subclasses_before)
  end

  def test_freeze_all_makes_an_unfrozen_table_name_shareable
    model = Class.new(Monk::Persistence::Model)
    model.db_name = :some_db
    model.table_name = +"widgets" # explicitly unfrozen

    refute model.table_name.frozen?

    Monk::Persistence::Model.freeze_all!

    assert model.table_name.frozen?
  end

  def test_freeze_all_raises_a_precise_error_for_an_unshareable_value
    model = Class.new(Monk::Persistence::Model)
    model.db_name = :some_db
    model.table_name = Mutex.new # can never be made shareable

    error = assert_raises(Monk::UnshareableModelError) { Monk::Persistence::Model.freeze_all! }

    assert_match(/#{Regexp.escape(model.to_s)}/, error.message)
  end

  def test_freeze_all_does_not_require_db_name_to_be_registered
    model = Class.new(Monk::Persistence::Model)
    model.db_name = :a_db_nobody_registered
    model.table_name = "widgets"

    Monk::Persistence::Model.freeze_all! # must not raise Monk::UnknownPersistenceError
  end

  def test_freeze_all_is_idempotent_across_repeated_calls
    model = Class.new(Monk::Persistence::Model)
    model.db_name = :some_db
    model.table_name = +"widgets"

    2.times { Monk::Persistence::Model.freeze_all! }

    assert model.table_name.frozen?
  end

  # The actual regression this phase exists for: without freeze_all!, a
  # Model subclass's table_name (a plain, unfrozen String) can't be read
  # from inside a worker Ractor at all -- Ractor::IsolationError -- even
  # though the class itself is always Ractor.shareable?.
  def test_app_boot_makes_a_models_config_readable_from_a_real_worker_ractor
    model = Class.new(Monk::Persistence::Model)
    model.db_name = :some_db
    model.table_name = +"widgets"

    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end
    app.freeze!

    result = Ractor.new(model) { |m| m.table_name }.value

    assert_equal "widgets", result
  end
end
