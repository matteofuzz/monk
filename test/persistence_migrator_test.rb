require_relative "test_helper"
require "tmpdir"
require "monk/persistence/pg/migrator"

class PersistenceMigratorTest < Minitest::Test
  include PersistenceTestHelpers

  DB_NAME = :persistence_migrator_test_db

  def setup
    Monk::Persistence::Pg.reset!
  end

  def teardown
    if postgres_available?
      begin
        Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_test_tables(conn) }
      rescue Monk::UnknownPersistenceError
      end
    end
    Monk::Persistence::Pg.reset!
  end

  def test_migrate_bang_creates_schema_migrations_and_applies_pending_migrations_in_order
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    dir = migrations_dir(
      "1_create_widgets" => { up: "CREATE TABLE widgets (id SERIAL PRIMARY KEY, name TEXT)", down: "DROP TABLE widgets" },
      "2_create_gadgets" => { up: "CREATE TABLE gadgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE gadgets" },
    )
    migrator = Monk::Persistence::Pg::Migrator.new(db_name: DB_NAME, dir: dir)

    applied = migrator.migrate!

    assert_equal ["1", "2"], applied
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      versions = conn.exec("SELECT version FROM schema_migrations ORDER BY version").map { |r| r["version"] }
      assert_equal ["1", "2"], versions
      refute_nil conn.exec("SELECT to_regclass('widgets')").getvalue(0, 0)
      refute_nil conn.exec("SELECT to_regclass('gadgets')").getvalue(0, 0)
    end
  end

  def test_migrate_bang_is_a_no_op_when_nothing_is_pending
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    dir = migrations_dir(
      "1_create_widgets" => { up: "CREATE TABLE widgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE widgets" },
    )
    migrator = Monk::Persistence::Pg::Migrator.new(db_name: DB_NAME, dir: dir)
    migrator.migrate!

    applied = migrator.migrate!

    assert_equal [], applied
  end

  def test_migrate_bang_rolls_back_and_halts_on_a_failing_migration
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    dir = migrations_dir(
      "1_create_widgets" => { up: "CREATE TABLE widgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE widgets" },
      "2_broken" => { up: "SELECT * FROM this_table_does_not_exist", down: "-- noop" },
      "3_create_things" => { up: "CREATE TABLE things (id SERIAL PRIMARY KEY)", down: "DROP TABLE things" },
    )
    migrator = Monk::Persistence::Pg::Migrator.new(db_name: DB_NAME, dir: dir)

    assert_raises(PG::Error) { migrator.migrate! }

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      versions = conn.exec("SELECT version FROM schema_migrations ORDER BY version").map { |r| r["version"] }
      assert_equal ["1"], versions
      refute_nil conn.exec("SELECT to_regclass('widgets')").getvalue(0, 0)
      assert_nil conn.exec("SELECT to_regclass('things')").getvalue(0, 0)
    end
  end

  def test_rollback_bang_reverts_the_most_recently_applied_migration_by_default
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    dir = migrations_dir(
      "1_create_widgets" => { up: "CREATE TABLE widgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE widgets" },
      "2_create_gadgets" => { up: "CREATE TABLE gadgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE gadgets" },
    )
    migrator = Monk::Persistence::Pg::Migrator.new(db_name: DB_NAME, dir: dir)
    migrator.migrate!

    reverted = migrator.rollback!

    assert_equal ["2"], reverted
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      versions = conn.exec("SELECT version FROM schema_migrations ORDER BY version").map { |r| r["version"] }
      assert_equal ["1"], versions
      refute_nil conn.exec("SELECT to_regclass('widgets')").getvalue(0, 0)
      assert_nil conn.exec("SELECT to_regclass('gadgets')").getvalue(0, 0)
    end
  end

  def test_rollback_bang_with_steps_reverts_multiple_most_recent_first
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    dir = migrations_dir(
      "1_create_widgets" => { up: "CREATE TABLE widgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE widgets" },
      "2_create_gadgets" => { up: "CREATE TABLE gadgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE gadgets" },
      "3_create_things" => { up: "CREATE TABLE things (id SERIAL PRIMARY KEY)", down: "DROP TABLE things" },
    )
    migrator = Monk::Persistence::Pg::Migrator.new(db_name: DB_NAME, dir: dir)
    migrator.migrate!

    reverted = migrator.rollback!(steps: 2)

    assert_equal ["3", "2"], reverted
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      versions = conn.exec("SELECT version FROM schema_migrations ORDER BY version").map { |r| r["version"] }
      assert_equal ["1"], versions
      refute_nil conn.exec("SELECT to_regclass('widgets')").getvalue(0, 0)
      assert_nil conn.exec("SELECT to_regclass('gadgets')").getvalue(0, 0)
      assert_nil conn.exec("SELECT to_regclass('things')").getvalue(0, 0)
    end
  end

  def test_rollback_bang_with_steps_beyond_applied_count_reverts_everything_and_stops_cleanly
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    dir = migrations_dir(
      "1_create_widgets" => { up: "CREATE TABLE widgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE widgets" },
      "2_create_gadgets" => { up: "CREATE TABLE gadgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE gadgets" },
    )
    migrator = Monk::Persistence::Pg::Migrator.new(db_name: DB_NAME, dir: dir)
    migrator.migrate!

    reverted = migrator.rollback!(steps: 10)

    assert_equal ["2", "1"], reverted
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      versions = conn.exec("SELECT version FROM schema_migrations").map { |r| r["version"] }
      assert_equal [], versions
    end
  end

  def test_rollback_bang_raises_a_precise_error_when_an_applied_migration_has_no_down_file_on_disk
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    dir = migrations_dir(
      "1_create_widgets" => { up: "CREATE TABLE widgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE widgets" },
    )
    Monk::Persistence::Pg::Migrator.new(db_name: DB_NAME, dir: dir).migrate!
    migrator = Monk::Persistence::Pg::Migrator.new(db_name: DB_NAME, dir: Dir.mktmpdir)

    error = assert_raises(Monk::MalformedMigrationError) { migrator.rollback! }

    assert_match(/1/, error.message)
  end

  def test_pending_and_applied_before_any_migration_has_run
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    dir = migrations_dir(
      "1_create_widgets" => { up: "CREATE TABLE widgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE widgets" },
    )
    migrator = Monk::Persistence::Pg::Migrator.new(db_name: DB_NAME, dir: dir)

    assert_equal ["1"], migrator.pending
    assert_equal [], migrator.applied
  end

  def test_pending_returns_not_yet_applied_versions_in_ascending_order_with_no_side_effects
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    first_dir = migrations_dir(
      "1_create_widgets" => { up: "CREATE TABLE widgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE widgets" },
    )
    Monk::Persistence::Pg::Migrator.new(db_name: DB_NAME, dir: first_dir).migrate!

    full_dir = migrations_dir(
      "1_create_widgets" => { up: "CREATE TABLE widgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE widgets" },
      "2_create_gadgets" => { up: "CREATE TABLE gadgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE gadgets" },
      "3_create_things" => { up: "CREATE TABLE things (id SERIAL PRIMARY KEY)", down: "DROP TABLE things" },
    )
    migrator = Monk::Persistence::Pg::Migrator.new(db_name: DB_NAME, dir: full_dir)

    assert_equal ["2", "3"], migrator.pending
    assert_equal ["1"], migrator.applied
  end

  def test_applied_returns_versions_in_the_order_they_were_applied
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    dir = migrations_dir(
      "1_create_widgets" => { up: "CREATE TABLE widgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE widgets" },
      "2_create_gadgets" => { up: "CREATE TABLE gadgets (id SERIAL PRIMARY KEY)", down: "DROP TABLE gadgets" },
    )
    migrator = Monk::Persistence::Pg::Migrator.new(db_name: DB_NAME, dir: dir)
    migrator.migrate!

    assert_equal ["1", "2"], migrator.applied
  end

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

  def drop_test_tables(conn)
    %w[schema_migrations widgets gadgets things].each { |t| conn.exec("DROP TABLE IF EXISTS #{t} CASCADE") }
  end

  def migrations_dir(migrations)
    dir = Dir.mktmpdir
    migrations.each do |basename, sql|
      File.write(File.join(dir, "#{basename}.up.sql"), sql[:up])
      File.write(File.join(dir, "#{basename}.down.sql"), sql[:down])
    end
    dir
  end
end
