-- Monk::Presence: who has a socket open, per WebSocket process, and each
-- subject's settled status. Why this shape:
-- docs/adr/0019-presence-per-process-rows-in-postgres-settled-once-per-transition.md.

-- One row per bin/websocket_server process, heartbeat every few seconds:
-- a process whose heartbeat stops stops counting its subjects. UNLOGGED,
-- as monk_presence: after a Postgres crash both come back empty, and
-- each process writes its own again.
CREATE UNLOGGED TABLE monk_presence_processes (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  hostname TEXT NOT NULL,
  pid INTEGER NOT NULL,
  heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One row per (process, subject) with a socket open there, or closed
-- less than the grace ago (gone_at). Rewritten all the time, so not
-- worth the WAL. No foreign key: a process row pruned first just means
-- its rows stop counting.
CREATE UNLOGGED TABLE monk_presence (
  process_id BIGINT NOT NULL,
  subject TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('online', 'away')),
  gone_at TIMESTAMPTZ,
  PRIMARY KEY (process_id, subject)
);
CREATE INDEX monk_presence_subject ON monk_presence (subject);

-- Each subject's last settled status, written once per transition, and
-- when it was last seen: shown to users, so logged.
CREATE TABLE monk_presence_status (
  subject TEXT PRIMARY KEY,
  status TEXT NOT NULL CHECK (status IN ('online', 'away', 'offline')),
  changed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ
);
