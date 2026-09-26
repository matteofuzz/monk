-- Monk::Jobs: a narrow state table, a payload table, one row per job
-- process. Why this shape: docs/adr/0013-jobs-narrow-state-table-plus-payloads.md.

-- Scheduling and state only, about 70 bytes a row: claiming a job
-- rewrites this row, never the payload.
CREATE TABLE monk_jobs (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  queue TEXT NOT NULL DEFAULT 'default',
  priority SMALLINT NOT NULL DEFAULT 0, -- lower runs sooner
  state TEXT NOT NULL CHECK (state IN ('available', 'scheduled', 'running', 'failed')),
  run_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  attempts SMALLINT NOT NULL DEFAULT 0,
  max_attempts SMALLINT NOT NULL DEFAULT 5,
  locked_by BIGINT, -- monk_processes.id while running
  locked_at TIMESTAMPTZ
);

-- One partial index per lookup, each holding only the rows it wants:
-- workers claim from the first, the stager promotes due jobs from the
-- second, pruning a dead process finds its jobs through the third.
CREATE INDEX monk_jobs_available ON monk_jobs (queue, priority, run_at, id) WHERE state = 'available';
CREATE INDEX monk_jobs_scheduled ON monk_jobs (run_at) WHERE state = 'scheduled';
CREATE INDEX monk_jobs_running ON monk_jobs (locked_by) WHERE state = 'running';

-- Every job's row is updated and deleted within seconds, so vacuum it
-- sooner than Postgres's defaults would (1% of rows dead rather than 20%,
-- and without cost-based throttling).
ALTER TABLE monk_jobs SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_cost_delay = 0);

-- Written once at enqueue, deleted with its job, updated only to record
-- an error.
CREATE TABLE monk_job_payloads (
  job_id BIGINT PRIMARY KEY REFERENCES monk_jobs (id) ON DELETE CASCADE,
  job_class TEXT NOT NULL,
  args JSONB NOT NULL,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One row per bin/jobs process: a heartbeat that stops means its
-- running jobs go back to available.
CREATE TABLE monk_processes (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  hostname TEXT NOT NULL,
  pid INTEGER NOT NULL,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
