require_relative "test_helper"
require "monk/persistence/pg/migrator"

# Monk::Jobs' tables (docs/adr/0013-jobs-narrow-state-table-plus-payloads.md,
# docs/history/plan-jobs.md Phase 1), applied from the one canonical
# migration the scaffold also copies -- so what an app gets and what these
# tests check can't drift apart.
class JobsSchemaTest < Minitest::Test
  include PersistenceTestHelpers

  DB_NAME = :jobs_schema_test_db
  MIGRATIONS_DIR = File.expand_path("../lib/monk/templates/jobs/db/migrate", __dir__)
  TABLES = %w[monk_job_payloads monk_jobs monk_processes monk_recurring_tasks].freeze

  def setup
    Monk::Persistence::Pg.reset!
    return unless postgres_available?

    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_jobs_tables(conn) }
  end

  def teardown
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_jobs_tables(conn) } if postgres_available?
    Monk::Persistence::Pg.reset!
  end

  def test_migrate_creates_every_jobs_table
    skip_unless_postgres_available

    migrator.migrate!

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      TABLES.each { |table| assert table_exists?(conn, table), "expected #{table} to exist" }
    end
  end

  # The partial indexes are the design (ADR 0013): each lookup only ever
  # sees the rows it wants, so scheduled or failed jobs never sit in the
  # index workers claim from.
  def test_migrate_creates_one_partial_index_per_state_lookup
    skip_unless_postgres_available

    migrator.migrate!

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      rows = conn.exec("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'monk_jobs'")
      indexes = rows.to_h { |r| [r["indexname"], r["indexdef"]] }

      assert_match(
        /\(queue, priority, run_at, id\) WHERE \(state = 'available'::text\)/, indexes.fetch("monk_jobs_available"),
      )
      assert_match(/\(run_at\) WHERE \(state = 'scheduled'::text\)/, indexes.fetch("monk_jobs_scheduled"))
      assert_match(/\(locked_by\) WHERE \(state = 'running'::text\)/, indexes.fetch("monk_jobs_running"))
    end
  end

  def test_an_unknown_state_is_rejected
    skip_unless_postgres_available
    migrator.migrate!

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      assert_raises(PG::CheckViolation) do
        conn.exec("INSERT INTO monk_jobs (state) VALUES ('done')")
      end
    end
  end

  def test_deleting_a_job_deletes_its_payload
    skip_unless_postgres_available
    migrator.migrate!

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      id = conn.exec("INSERT INTO monk_jobs (state) VALUES ('available') RETURNING id").getvalue(0, 0)
      conn.exec_params(
        "INSERT INTO monk_job_payloads (job_id, job_class, args) VALUES ($1, 'SendReceipt', '[42]')", [id],
      )

      conn.exec_params("DELETE FROM monk_jobs WHERE id = $1", [id])

      assert_equal 0, conn.exec_params("SELECT count(*) FROM monk_job_payloads WHERE job_id = $1", [id]).getvalue(0, 0)
    end
  end

  def test_a_new_job_gets_the_documented_defaults
    skip_unless_postgres_available
    migrator.migrate!

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      row = conn.exec("INSERT INTO monk_jobs (state) VALUES ('available') RETURNING *").first

      assert_equal "default", row["queue"]
      assert_equal 0, row["priority"]
      assert_equal 0, row["attempts"]
      assert_equal 5, row["max_attempts"]
      assert_nil row["locked_by"]
      assert_nil row["locked_at"]
      refute_nil row["run_at"]
    end
  end

  # Not measured in Phase 0 -- the Solid Queue guides' advice for a
  # high-churn queue table -- but asserted so it can't silently fall out
  # of the migration.
  def test_monk_jobs_is_vacuumed_more_eagerly_than_the_default
    skip_unless_postgres_available
    migrator.migrate!

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      options = conn.exec("SELECT reloptions FROM pg_class WHERE relname = 'monk_jobs'").getvalue(0, 0)

      assert_includes options, "autovacuum_vacuum_scale_factor=0.01"
      assert_includes options, "autovacuum_vacuum_cost_delay=0"
    end
  end

  # One checkpoint row per recurring task, keyed by the declared key
  # (docs/history/plan-scheduled-jobs.md decision 4).
  def test_a_recurring_task_row_is_keyed_and_starts_with_no_job
    skip_unless_postgres_available
    migrator.migrate!

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      insert = "INSERT INTO monk_recurring_tasks (key, cron, last_occurrence_at) VALUES ('purge', '@daily', now())"
      row = conn.exec("#{insert} RETURNING *").first

      assert_nil row["last_job_id"]
      refute_nil row["updated_at"]
      assert_raises(PG::UniqueViolation) { conn.exec(insert) }
    end
  end

  # Decision 4: no foreign key to monk_jobs. A job finishing (and being
  # deleted) must not touch the task's row.
  def test_a_recurring_tasks_last_job_id_may_point_at_a_finished_job
    skip_unless_postgres_available
    migrator.migrate!

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec(<<~SQL)
        INSERT INTO monk_recurring_tasks (key, cron, last_occurrence_at, last_job_id) VALUES ('purge', '@daily', now(), 999)
      SQL

      assert_equal 0, conn.exec(<<~SQL).getvalue(0, 0)
        SELECT count(*) FROM pg_constraint WHERE conrelid = 'monk_recurring_tasks'::regclass AND contype = 'f'
      SQL
    end
  end

  # Rolling back the recurring migration alone leaves the queue in place.
  def test_one_rollback_drops_only_the_recurring_table
    skip_unless_postgres_available
    migrator.migrate!

    migrator.rollback!

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      refute table_exists?(conn, "monk_recurring_tasks")
      assert table_exists?(conn, "monk_jobs")
    end
  end

  def test_rollback_drops_every_jobs_table
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

  def drop_jobs_tables(conn)
    (TABLES + ["schema_migrations"]).each { |t| drop_table_if_exists(conn, t, cascade: true) }
  end
end
