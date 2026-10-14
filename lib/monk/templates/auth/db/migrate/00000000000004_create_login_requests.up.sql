-- Monk::Auth housekeeping (Monk 0.22): the login-email rate limit's table
-- and an index for finding a person's sessions.

-- One row per address: when a login link was last requested for it, for
-- Monk::Auth.allow_login_request?. Checked in the login route, before the
-- link is sent or enqueued: with jobs the login token only exists once the
-- job runs, so login_tokens can't tell a request is already queued.
-- Monk::Auth.sweep! deletes rows older than login_request_interval.
CREATE TABLE login_requests (
  email TEXT PRIMARY KEY, -- stripped and downcased
  requested_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- A person's sessions by subject: Monk::Auth.revoke_all, or who is online.
-- An app that already has an index on sessions (subject) can drop this line.
CREATE INDEX sessions_subject ON sessions (subject);
