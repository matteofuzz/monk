require_relative "test_helper"
require "tmpdir"
require "monk/persistence/pg/migrator"

class PersistenceMigratorTest < Minitest::Test
  def test_lists_up_down_pairs_in_ascending_version_order
    dir = migrations_dir(
      "20260301000000_create_gadgets" => { up: "CREATE TABLE gadgets ()", down: "DROP TABLE gadgets" },
      "20260101000000_create_widgets" => { up: "CREATE TABLE widgets ()", down: "DROP TABLE widgets" },
      "20260201000000_add_widgets_index" => { up: "CREATE INDEX widgets_idx ON widgets (id)", down: "DROP INDEX widgets_idx" },
    )

    migrator = Monk::Persistence::Pg::Migrator.new(db_name: :whatever, dir: dir)

    assert_equal(
      ["20260101000000", "20260201000000", "20260301000000"],
      migrator.migrations.map(&:version)
    )
    assert_equal ["create_widgets", "add_widgets_index", "create_gadgets"], migrator.migrations.map(&:name)
  end

  def test_ordering_is_numeric_not_lexical
    dir = migrations_dir(
      "2_seed" => { up: "-- up", down: "-- down" },
      "10_more" => { up: "-- up", down: "-- down" },
      "9_another" => { up: "-- up", down: "-- down" },
    )

    migrator = Monk::Persistence::Pg::Migrator.new(db_name: :whatever, dir: dir)

    assert_equal ["2", "9", "10"], migrator.migrations.map(&:version)
  end

  def test_raises_a_precise_error_for_a_filename_that_does_not_match_the_convention
    dir = Dir.mktmpdir
    File.write(File.join(dir, "not_a_migration.sql"), "SELECT 1")

    error = assert_raises(Monk::MalformedMigrationError) do
      Monk::Persistence::Pg::Migrator.new(db_name: :whatever, dir: dir)
    end

    assert_match(/not_a_migration\.sql/, error.message)
  end

  def test_raises_a_precise_error_for_an_up_file_with_no_matching_down
    dir = Dir.mktmpdir
    File.write(File.join(dir, "20260101000000_create_widgets.up.sql"), "CREATE TABLE widgets ()")

    error = assert_raises(Monk::MalformedMigrationError) do
      Monk::Persistence::Pg::Migrator.new(db_name: :whatever, dir: dir)
    end

    assert_match(/20260101000000_create_widgets/, error.message)
    assert_match(/down/, error.message)
  end

  def test_raises_a_precise_error_for_a_down_file_with_no_matching_up
    dir = Dir.mktmpdir
    File.write(File.join(dir, "20260101000000_create_widgets.down.sql"), "DROP TABLE widgets")

    error = assert_raises(Monk::MalformedMigrationError) do
      Monk::Persistence::Pg::Migrator.new(db_name: :whatever, dir: dir)
    end

    assert_match(/20260101000000_create_widgets/, error.message)
    assert_match(/up/, error.message)
  end

  def test_raises_a_precise_error_when_the_same_version_names_two_different_migrations
    dir = Dir.mktmpdir
    File.write(File.join(dir, "1_create_widgets.up.sql"), "CREATE TABLE widgets ()")
    File.write(File.join(dir, "1_create_widgets.down.sql"), "DROP TABLE widgets")
    File.write(File.join(dir, "1_create_gadgets.up.sql"), "CREATE TABLE gadgets ()")

    error = assert_raises(Monk::MalformedMigrationError) do
      Monk::Persistence::Pg::Migrator.new(db_name: :whatever, dir: dir)
    end

    assert_match(/1/, error.message)
    assert_match(/create_widgets/, error.message)
    assert_match(/create_gadgets/, error.message)
  end

  private

  def migrations_dir(migrations)
    dir = Dir.mktmpdir
    migrations.each do |basename, sql|
      File.write(File.join(dir, "#{basename}.up.sql"), sql[:up])
      File.write(File.join(dir, "#{basename}.down.sql"), sql[:down])
    end
    dir
  end
end
