-- Monk::Jobs.recurring: one checkpoint row per declared task, the latest
-- occurrence it has been handled for. Why this shape:
-- docs/adr/0016-recurring-jobs-on-the-job-process-tick-with-a-checkpoint-row.md.
CREATE TABLE monk_recurring_tasks (
  key TEXT PRIMARY KEY, -- the key given to Monk::Jobs.recurring
  cron TEXT NOT NULL, -- the expression the checkpoint was set under
  last_occurrence_at TIMESTAMPTZ NOT NULL, -- the checkpoint
  -- The job enqueued for the checkpoint, for skip_if_pending. No foreign
  -- key: ON DELETE SET NULL would add a write to every job's finish, and
  -- a dangling id just means that job is done.
  last_job_id BIGINT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
