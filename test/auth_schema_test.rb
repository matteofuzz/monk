require_relative "test_helper"
require "monk/persistence/pg/migrator"

# Monk::Auth's tables, applied from the canonical migrations monk add auth
# copies, so what an app gets and what these tests check can't drift apart
# (docs/plan-auth-housekeeping.md Phase 1).
class AuthSchemaTest < Minitest::Test
  include PersistenceTestHelpers

  DB_NAME = :auth_schema_test_db
  MIGRATIONS_DIR = File.expand_path("../lib/monk/templates/auth/db/migrate", __dir__)
  TABLES = %w[login_tokens sessions login_requests].freeze

  def setup
    Monk::Persistence::Pg.reset!
    return unless postgres_available?

    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_auth_tables(conn) }
  end

  def teardown
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_auth_tables(conn) } if postgres_available?
    Monk::Persistence::Pg.reset!
  end

  def test_migrate_creates_every_auth_table
    skip_unless_postgres_available

    migrator.migrate!

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      TABLES.each { |table| assert table_exists?(conn, table), "expected #{table} to exist" }
    end
  end

  # Decision 4: looking up a person's sessions (revoke_all, who's online)
  # doesn't scan the table.
  def test_sessions_are_indexed_by_subject
    skip_unless_postgres_available
    migrator.migrate!

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      indexdef = conn.exec("SELECT indexdef FROM pg_indexes WHERE indexname = 'sessions_subject'").getvalue(0, 0)

      assert_match(/ON public\.sessions USING btree \(subject\)\z/, indexdef)
    end
  end

  # Decision 5: one row per address, the time of its last login request.
  def test_a_login_request_is_one_row_per_email
    skip_unless_postgres_available
    migrator.migrate!

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      row = conn.exec("INSERT INTO login_requests (email) VALUES ('ann@example.test') RETURNING *").first

      refute_nil row["requested_at"]
      assert_raises(PG::UniqueViolation) { conn.exec("INSERT INTO login_requests (email) VALUES ('ann@example.test')") }
    end
  end

  # The housekeeping migration alone rolls back to auth's original schema.
  def test_one_rollback_drops_login_requests_and_the_subject_index
    skip_unless_postgres_available
    migrator.migrate!

    migrator.rollback!

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      refute table_exists?(conn, "login_requests")
      assert table_exists?(conn, "sessions")
      assert_equal 0, conn.exec("SELECT count(*) FROM pg_indexes WHERE indexname = 'sessions_subject'").getvalue(0, 0)
    end
  end

  def test_rollback_drops_every_auth_table
    skip_unless_postgres_available
    migrator.migrate!

    migrator.rollback!(steps: 2)

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      TABLES.each { |table| refute table_exists?(conn, table), "expected #{table} to be dropped" }
    end
  end

  private

  def migrator
    Monk::Persistence::Pg::Migrator.new(db_name: DB_NAME, dir: MIGRATIONS_DIR)
  end

  def drop_auth_tables(conn)
    (TABLES + ["schema_migrations"]).each { |t| drop_table_if_exists(conn, t, cascade: true) }
  end
end
