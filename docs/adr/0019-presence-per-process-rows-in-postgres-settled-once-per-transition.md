# Presence is kept as per-process rows in Postgres, read by any process, and each change of status is settled once in a status table

An app wants to show whether a person is online, on phones as well as desktops (roadmap item 3, `docs/plan-live-networks-presence.md`). The page that shows the status is rendered by `bin/server`, which holds no sockets. The sockets are in one or more `bin/websocket_server` processes, possibly on several hosts, any of which can stop or crash without cleaning up. A connect must not cost a query, since a WebSocket deploy reconnects every page within seconds (25K in the connect benchmark). A phone that switches network is offline for a few seconds, and a deploy drops every socket at once, and neither should read as "went offline" to the people watching. What a phone does to a socket was measured on real devices for this decision (the plan's A0): a locked iPhone resets the page's socket after about 16 s (3 s after switching apps), Android keeps it for about 5 minutes in Chrome, and both come back within a second of being looked at again.

Already decided in the plan: presence lives in Postgres, even for apps on the Redis transport (open question 4); only `Monk::Auth` subjects are tracked, one subject counted once across tabs and devices (B0, item 8); Away is inferred from the Live client's heartbeat, with no new message type (open question 6); it ships as `monk add presence` (open question 5).

We decided that each WebSocket process counts its own sockets in memory, per subject, and writes what changed once a second as rows of its own in an `UNLOGGED` table, `monk_presence (process_id, subject, status, gone_at)`. `status` is `online` (a visible page open) or `away` (only hidden pages). When a subject's last socket in that process closes, the row isn't deleted: it gets `gone_at` and keeps the status it had. Each process keeps a heartbeat row in `monk_presence_processes (id, hostname, pid, heartbeat_at)`, as `Monk::Jobs` does. A row counts while its process is alive (heartbeat within `PROCESS_TIMEOUT`) and, once gone, for `grace` more. A subject's status is the best of its counting rows, `online` over `away`, and `offline` without any. Readers compute that with one query, from any process. Every WS process's tick also settles transitions into a logged table, `monk_presence_status (subject PRIMARY KEY, status, changed_at, last_seen_at)`, with an upsert that only writes, and only returns, a status that differs from the stored one. Row locking makes exactly one process get each transition back, and that process calls the app's `on_change` hook. Every time is the database's `now()`, so hosts' clocks don't matter.

## How the pieces fit

- **Counting, no query per connect.** `Server.serve` tells a per-process presence Ractor when an authenticated socket opens (after the 101) and closes (in its ensure), with a send, not an ask, so a connect never waits on it. The Ractor holds subject → open sockets and visible sockets, and which subjects changed since the last flush. A flusher thread in the main Ractor takes that diff once a second and writes it in one statement (arrays through `unnest`: upsert the subjects with sockets, set `gone_at = now()` on those down to zero). Nothing is remembered for a subject once its zero is written. A reconnect to the same process in the grace upserts the row back to `gone_at = NULL`.
- **Away, from the Live heartbeat.** A Live socket is visible while the server has had a `{"op":"ping"}` from it within `2 × HEARTBEAT` (50 s). `Live::Session` tells the presence Ractor when a socket crosses that line, either way. A Live socket starts out hidden. The client pings at once on open when its page is visible, so a visible page is online within a frame, and a hidden page's reconnect doesn't read as Online. A socket that never sends Live pings (an `app/sockets` client) counts as visible: it has no Away. The server's `HEARTBEAT` mirrors `protocol.js`'s, with a test that fails if they differ. So the client's ping schedule is part of what Away means: changing when the client pings changes Away, and this ADR is where that rule is written.
- **Grace before offline, where the row is.** A closed socket's row keeps counting, with its last status, for `grace` (20 s by default, `Monk::Presence.configure(grace:)`). A subject reconnecting anywhere in that time never reads as offline. Online and Away change without grace: Away already takes 50 s of silence, and coming back is meant to show at once.
- **A process that stops.** On `TERM` it sets `gone_at = now()` on all its rows and stops heartbeating. The rows count for the grace, while its pages reconnect to the new process, so a deploy changes nobody's status. Deleting its rows instead would turn everyone offline for the second it takes them to reconnect.
- **A process that crashes.** Its rows count until its heartbeat is older than `PROCESS_TIMEOUT` (30 s, heartbeat every 5 s on the flush tick). Its pages reconnect to another process within a second, so only subjects with nowhere else to go turn offline, about 30 s after the crash.
- **Settling and pruning, by any process.** Each tick, a WS process takes the subjects it just flushed and those whose rows have expired (gone past the grace, or of a dead process), settles them into `monk_presence_status`, and deletes the expired rows and dead processes, in one transaction. The upsert's `WHERE status IS DISTINCT FROM excluded.status` makes a second process settling the same subject see no change once the first has committed, so each transition is returned once. Going offline, `last_seen_at` is taken from the expired rows: the latest `gone_at`, or a dead process's last heartbeat. A full reconcile of every non-offline subject runs every minute too, for transitions no expiry announces: the `UNLOGGED` rows emptied by a Postgres crash, or a process that came back with a new id.
- **Readers.** `Monk::Presence.status(subjects)` returns `{subject => {status:, last_seen_at:}}` (`:online`, `:away` or `:offline`; `last_seen_at` for the offline ones), and `online?(subject)`. One query for the people on screen: the counting rows for those subjects, joined to their processes, plus `monk_presence_status` for `last_seen_at`. Readers derive the status from the rows, not from `monk_presence_status`. If every WS process is down, nobody settles, and a stored `online` would never turn `offline`, while rows of dead processes stop counting by themselves.
- **`on_change`.** `Monk::Presence.on_change { |subject, status, last_seen_at| … }` in `config/presence.rb`, called on the settling process's flusher thread after its transaction commits, once per transition (`online`↔`away`, either to `offline` after the grace, `offline` to either). The app calls `Monk::Live.patch` from it. It is at most once: a process that dies between commit and call loses that call. That's acceptable for a live dot, since a page is current again on its next resync, and it's the documented contract. An error in the hook is logged and doesn't stop the flusher.
- **Failures.** The flusher, heartbeat and settling share one connection (pool `:presence`, size 1). An error is logged, never ends the process, and after reconnecting the process rewrites all its rows from memory. While it can't write, its rows stop counting after `PROCESS_TIMEOUT`, so its subjects can read as offline until it's back.

## What a status means, measured

- **A locked iPhone is Offline** about 36 s after locking (16 s for iOS to reset the socket, then the grace), and Online again within a second of unlock. It reads Online, not Away, until then: iOS resets the socket before 50 s of missing pings make it Away. Telling "phone in a pocket" from "closed the app" isn't possible through a WebSocket on iOS. That is what Reachable is for, 0.25's push subscriptions, kept by the app. A longer grace for sockets closed while hidden was considered and left out: it would show Online for a phone that can't receive anything.
- **A locked Android phone is Away** after about 50 s and Offline after about 5 minutes in Chrome, when Android resets the socket.
- **A hidden desktop tab is Away** after about 50 s, and Online at once when shown (the client's probe ping).
- **Visible isn't "at the keyboard"**: an unattended desktop tab reads as Online. Idle detection is out of scope.
- **Offline shows after** the close plus the grace (20 s), or the process timeout for a crash (30 s), plus up to a tick. A peer that vanished silently is first closed by the server's idle timeout, `2 × ping_interval` (50 s in the scaffold).

## Tables

- `monk_presence` and `monk_presence_processes` are `UNLOGGED`: rows are rewritten all the time, skipping the WAL is the point, and after a Postgres crash they come back empty and each WS process rewrites its own. To confirm by measurement in B1 (a 25K connect wave, logged against unlogged). Unlogged tables don't reach read replicas, so presence is read from the primary. Monk doesn't route reads to replicas today, and the guide says so.
- `monk_presence_status` is logged. `last_seen_at` is shown to users and must survive a crash, and it is written once per transition, not per connect. It keeps one row per subject ever seen, like the sessions an app already has.
- One numbered migration in the `presence` template, `00000000000005_create_presence_tables`, written by `monk add presence`.

## Considered Options

Where the shared state lives:

- **Each process's memory, shared through the fanout** (rejected: `bin/server` has no sockets and nothing to ask, and a process started late never hears who joined before it)
- **Redis, a hash per process with a TTL** (rejected: only apps on the Redis transport have it, and presence needs `Monk::Auth`, so Postgres anyway, plan open question 4)
- **Postgres** (chosen)

Where the grace and the transitions are decided:

- **Delete a process's row when its count reaches zero, and let readers see offline at once** (rejected: every network switch and every deploy reads as going offline)
- **A delayed job per going-offline subject, checking again after the grace** (rejected: a job per close in a reconnect wave, and `Monk::Jobs` would become a requirement of presence)
- **The process that saw the close decides after the grace, from memory** (rejected: the process that saw it may be the one stopping, and it can't know whether another process has the subject)
- **Rows kept with `gone_at` for the grace, readers deriving status, transitions settled by an upsert any process runs** (chosen: readers need no writes and are right even with every WS process down, deploys don't flap, and no single process has to survive for a transition to happen)
- **The status table as the only truth for readers** (rejected: with every WS process down, nobody settles, and statuses stay `online` forever)

Away:

- **Inferred from Live's own heartbeat** (chosen, plan open question 6)
- **An explicit `{"op":"visibility"}` message** (rejected: instant, but the first client-to-server message in Live that isn't about subscriptions, for a status that tolerates 50 s)
- **Closing hidden pages' sockets and deriving Away from how recently they were seen** (rejected: no live updates in background tabs, and a refetch on every return)
- **Left to apps** (rejected: only possible through a second channel, an HTTP post or another socket, which races the Live one)

Hearing about changes:

- **`on_change`, called once per transition by the process that settled it** (chosen)
- **Apps polling `status`** (rejected: loses what makes it live)
- **A Live topic Monk publishes presence to** (left out: which pages show whose status, and how, is the app's; it can publish from `on_change` in one line)

Also left out: presence for anonymous sockets (a future route is a `Monk::Auth` session for any subject, such as `"guest:…"`, plan B0 item 8), a Redis store behind the same reader API (possible later without breaking anything), presence history, and idle detection.
