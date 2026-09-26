require "json"
require "time"
require_relative "../../persistence/pg"
require_relative "../claim"

module Monk
  module Jobs
    module Adapters
      # The queue on Postgres: monk_jobs + monk_job_payloads + monk_processes
      # (docs/adr/0013-jobs-narrow-state-table-plus-payloads.md). Holds only
      # the registered database's name and freezes itself, so the one
      # instance is shareable with every Ractor; each Ractor reaches the
      # database through its own connection, via Monk::Persistence::Pg.
      class Pg
        # One statement, so a job and its payload are written together even
        # outside a transaction. The database clock decides run_at, and so
        # whether the job starts scheduled or available -- an app server's
        # clock running a little ahead can't make a job look due early.
        ENQUEUE_SQL = <<~SQL.freeze
          WITH due AS (
            SELECT COALESCE($4::timestamptz, now() + COALESCE($5::float8, 0) * interval '1 second') AS run_at
          ), job AS (
            INSERT INTO monk_jobs (queue, priority, max_attempts, run_at, state)
            SELECT $1::text, $2::smallint, $3::smallint, run_at,
              CASE WHEN run_at > now() THEN 'scheduled' ELSE 'available' END
            FROM due
            RETURNING id
          )
          INSERT INTO monk_job_payloads (job_id, job_class, args)
          SELECT id, $6::text, $7::jsonb FROM job
          RETURNING job_id
        SQL

        # Decision 2: the claim rewrites only the narrow monk_jobs row. args
        # comes back as text and is parsed here rather than by the
        # connection's result type map, so it decodes the same whichever
        # connection runs it.
        CLAIM_SQL = <<~SQL.freeze
          WITH claimed AS (
            UPDATE monk_jobs
            SET state = 'running', locked_by = $2, locked_at = now(), attempts = attempts + 1
            WHERE id = (
              SELECT id FROM monk_jobs
              WHERE queue = $1 AND state = 'available'
              ORDER BY priority, run_at, id
              FOR UPDATE SKIP LOCKED
              LIMIT 1
            )
            RETURNING id, attempts
          )
          SELECT claimed.id, claimed.attempts, payload.job_class, payload.args::text AS args
          FROM claimed JOIN monk_job_payloads payload ON payload.job_id = claimed.id
        SQL

        # Only while this process still holds the job: one pruned from a dead
        # process and claimed again elsewhere isn't deleted by the first
        # worker finishing late. The payload goes by ON DELETE CASCADE.
        FINISH_SQL = <<~SQL.freeze
          DELETE FROM monk_jobs WHERE id = $1 AND state = 'running' AND locked_by = $2
        SQL

        # Only while this process still holds the job, like FINISH_SQL. The
        # database decides where it goes: back to scheduled, due retry_in
        # seconds from now, or to failed once it has used its last attempt
        # (attempts was already counted when it was claimed) or when
        # retry_in is NULL. The payload keeps the error either way; the
        # payload update runs whether or not the final SELECT reads it.
        FAIL_SQL = <<~SQL.freeze
          WITH job AS (
            UPDATE monk_jobs SET
              state = CASE WHEN $3::float8 IS NULL OR attempts >= max_attempts THEN 'failed' ELSE 'scheduled' END,
              run_at = CASE WHEN $3::float8 IS NULL OR attempts >= max_attempts THEN run_at
                            ELSE now() + $3::float8 * interval '1 second' END,
              locked_by = NULL, locked_at = NULL
            WHERE id = $1 AND state = 'running' AND locked_by = $2
            RETURNING id, state
          ), payload AS (
            UPDATE monk_job_payloads SET last_error = $4 FROM job WHERE monk_job_payloads.job_id = job.id
          )
          SELECT state FROM job
        SQL

        # The stager: due scheduled jobs become available, oldest first, at
        # most $1 per call. SKIP LOCKED lets every job process stage at
        # once without two of them moving the same job.
        STAGE_SQL = <<~SQL.freeze
          UPDATE monk_jobs SET state = 'available'
          WHERE id IN (
            SELECT id FROM monk_jobs
            WHERE state = 'scheduled' AND run_at <= now()
            ORDER BY run_at
            LIMIT $1
            FOR UPDATE SKIP LOCKED
          )
        SQL

        RETRY_FAILED_SQL = <<~SQL.freeze
          UPDATE monk_jobs SET state = 'available', attempts = 0, run_at = now() WHERE id = $1 AND state = 'failed'
        SQL

        DISCARD_FAILED_SQL = <<~SQL.freeze
          DELETE FROM monk_jobs WHERE id = $1 AND state = 'failed'
        SQL

        CLEAR_SQL = <<~SQL.freeze
          DELETE FROM monk_jobs;
          DELETE FROM monk_processes;
        SQL

        attr_reader :db_name

        def initialize(db_name:)
          @db_name = db_name
          freeze
        end

        # Returns the new job's id. conn: runs it on a connection the caller
        # already holds, inside the caller's transaction -- required rather
        # than optional there, since checking out the same Ractor's
        # connection again would wait on itself.
        def enqueue(job_class:, queue:, priority:, max_attempts:, args:, wait: nil, at: nil, conn: nil)
          params = [queue, priority, max_attempts, at&.utc&.iso8601(6), wait&.to_f, job_class, args]
          with_connection(conn) { |c| Integer(c.exec_params(ENQUEUE_SQL, params).getvalue(0, 0)) }
        end

        # The next available job on `queue`, now running for process_id, or
        # nil when there's none.
        def claim(queue, process_id)
          row = with_connection { |c| c.exec_params(CLAIM_SQL, [queue, process_id]).first }
          return nil unless row

          Claim.new(
            id: Integer(row["id"]), job_class: row["job_class"],
            args: JSON.parse(row["args"]), attempts: Integer(row["attempts"]),
          )
        end

        # True if the job was deleted, false if process_id no longer held it.
        def finish(id, process_id)
          with_connection { |c| c.exec_params(FINISH_SQL, [id, process_id]).cmd_tuples == 1 }
        end

        # Records a failure of a job process_id holds: :scheduled when it will
        # be retried in retry_in seconds, :failed when it won't (no attempts
        # left, or retry_in nil), nil when process_id no longer held it.
        def fail(id, process_id, error:, retry_in:)
          row = with_connection { |c| c.exec_params(FAIL_SQL, [id, process_id, retry_in&.to_f, error]).first }
          row && row["state"].to_sym
        end

        # Moves up to `limit` due scheduled jobs to available; returns how many.
        def stage_due(limit = 500)
          with_connection { |c| c.exec_params(STAGE_SQL, [limit]).cmd_tuples }
        end

        # A failed job back to available with fresh attempts. False if it
        # isn't failed (or doesn't exist).
        def retry_failed(id)
          with_connection { |c| c.exec_params(RETRY_FAILED_SQL, [id]).cmd_tuples == 1 }
        end

        # Deletes a failed job and its payload. False if it isn't failed.
        def discard_failed(id)
          with_connection { |c| c.exec_params(DISCARD_FAILED_SQL, [id]).cmd_tuples == 1 }
        end

        # Every job (payloads by cascade) and every process row. Behind
        # Monk::Jobs.clear!, which only runs in tests.
        def clear!
          with_connection { |c| c.exec(CLEAR_SQL) }
          nil
        end

        private

        def with_connection(conn = nil, &)
          conn ? yield(conn) : Monk::Persistence::Pg.checkout(@db_name, &)
        end
      end
    end
  end
end
