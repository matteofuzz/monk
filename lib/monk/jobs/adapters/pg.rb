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

        private

        def with_connection(conn = nil, &)
          conn ? yield(conn) : Monk::Persistence::Pg.checkout(@db_name, &)
        end
      end
    end
  end
end
