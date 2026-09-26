# Monk::Jobs — background jobs on Postgres — implementation plan

> **Historical document.** It records how this was planned or built at the time and may describe things that have since changed or shipped. For how Monk works today, see [`docs/guides/`](../guides/).

Branch: `main_dev/monk_jobs`. Nothing in this plan is implemented yet.
Companion record: [`../adr/0013-jobs-queue-split-across-postgres-tables.md`](../adr/0013-jobs-queue-split-across-postgres-tables.md)
(why the queue is split across several tables rather than kept in one,
why workers poll, and why no existing gem fits).

Same approach as `plan-websocket.md`/`plan-live-pg-fanout.md`: small red →
green slices, one failing test per seam, minimum code to pass. Ruby
4.0.6. Ractor behavior and Postgres behavior are measured against a
real test Postgres, never assumed.

## Naming and packaging

`Monk::Jobs` (the runtime, config and adapters) and `Monk::Job` (the
base class an app's jobs inherit from), in `lib/monk/jobs.rb` +
`lib/monk/jobs/`. Opt-in like every other Monk feature: `require
"monk/jobs"` explicitly, `require "monk"` alone never loads it. The
Postgres adapter needs `pg` and a connection registered through
`Monk::Persistence::Pg`, the same posture as `Monk::Auth`. The in-memory
adapter needs nothing. Monk takes on no runtime dependency.

Proposed layout (to be confirmed as phases land):

```
lib/monk/jobs.rb                 # configure, enqueue, freeze_registry!
lib/monk/jobs/job.rb             # Monk::Job base class + class registry
lib/monk/jobs/errors.rb
lib/monk/jobs/adapters/pg.rb     # the six-table queue
lib/monk/jobs/adapters/memory.rb # same contract, a StateRactor-style queue
lib/monk/jobs/runtime.rb         # supervisor (main Ractor), dispatcher and worker Ractors
```

## Decisions locked in before Phase 1

The storage design is ADR 0013. The rest are recommendations from the
same analysis, turned into plan assumptions here. Reversing one
invalidates the phases that depend on it.

1. **Six tables** (ADR 0013): `monk_jobs` (payload: `job_class`,
   `args jsonb`, `queue`, `priority`, `attempts`, `max_attempts`,
   timestamps), `monk_ready_executions` (`job_id, queue, priority,
   created_at`, index `(queue, priority, job_id)`),
   `monk_scheduled_executions` (`job_id, run_at, queue, priority`),
   `monk_claimed_executions` (`job_id, process_id, claimed_at`),
   `monk_failed_executions` (`job_id, error, failed_at`), `monk_processes`
   (`id, name, pid, hostname, last_heartbeat_at`). Every move between
   state tables happens in one transaction.
2. **Claiming a job** is a single `DELETE … FROM monk_ready_executions
   WHERE job_id IN (SELECT … ORDER BY priority, job_id FOR UPDATE SKIP
   LOCKED LIMIT $n) RETURNING …`, followed by an insert into claimed, in
   the same transaction. Each worker claims as many jobs as it has free
   slots (1 per worker Ractor in v1).
3. **Workers poll by default**, with a short, configurable interval. `LISTEN`/`NOTIFY`
   is an opt-in wake-up only (Phase 7), never how jobs are delivered
   (ADR 0013).
4. **Delivery is at-least-once.** Claims of a process whose heartbeat
   has expired go back to ready. Jobs must be idempotent, and the guide
   says so first.
5. **A finished job is deleted.** Optional retention of finished jobs is out of
   scope for v1.
6. **Jobs are classes, not blocks.** `class SendReceipt < Monk::Job; def
   self.perform(order_id) … end; end`. A Class is always shareable, so the
   job's code is callable from every worker Ractor without the
   `make_shareable` dance a Proc needs (`docs/design/ractor.md`). `args`
   must be plain JSON (String, Integer, Float, true/false/nil, Array, Hash
   with String keys) and are checked at enqueue, not when the job runs.
7. **Job classes register at load time and are frozen at `Boot`**
   through `Monk.freeze_hooks`, the same seam as `Persistence`, `Auth` and
   `Mail`. A worker looks up `job_class` in that frozen registry, never
   with `Object.const_get` on a string from the database. An unknown name
   fails the job straight away (no retries) with a clear error.
8. **The worker process is separate from the web server**: `bin/jobs`,
   the same model as `bin/websocket_server` (`plan-websocket.md` Decision
   1). Its main Ractor is the supervisor (signals, heartbeat, pruning). It
   runs one dispatcher Ractor and N worker Ractors, and each Ractor opens
   its own `PG::Connection` through `Monk::Persistence::Pg`'s per-Ractor
   registry. Monk does not run job workers inside Kino's process.
9. **Enqueueing is a plain insert on the caller's connection.** By
   default `enqueue` does its own `Monk::Persistence::Pg.checkout`. An
   explicit `conn:` argument makes it run on a connection the caller
   already holds, inside that caller's transaction. That's required, not
   optional sugar: `checkout` is a `SizedQueue(1)` per Ractor, so a nested
   `checkout` inside an open one would wait until it timed out.
10. **Retries are owned by the queue.** A job that raises is moved to
    `monk_scheduled_executions` with backoff (`attempts ** 4 + 15` seconds, Sidekiq-shaped, to be
    confirmed) until `max_attempts` (default 5). After that it moves to
    `monk_failed_executions`. `Monk::Jobs.retry_failed(job_id)` moves it
    back to ready.
11. **Two adapters, one contract**: `enqueue`, `claim(queues, process_id,
    limit)`, `finish`, `fail(retry_at:)`, `promote_due(limit)`,
    `heartbeat`, `prune(threshold)`. Postgres for real use. In-memory for
    tests and development, with a `drain!` that runs every ready job
    synchronously in the calling Ractor.
12. **Scaffolding**: `monk new --jobs` implies `--postgres`, the same way
    `--auth` does (Phase 8).

## Seams

- **Seam A — `Monk::Job` and the class registry**, no database: arguments are
  checked when a job is enqueued, the registry is sealed at `Boot`, and a job class is reachable
  from a worker Ractor after `Monk.freeze!`.
- **Seam B — the adapter contract**, one shared test suite run against
  both adapters (Postgres against the real test database), no Ractor runtime
  involved.
- **Seam C — the Ractor runtime in one process**: supervisor, dispatcher
  and worker Ractors against the Postgres adapter; concurrency and
  failure handling.
- **Seam D — a real separate process**: `bin/jobs`-style child process,
  enqueue from the test process, kill -9 and graceful stop, mirroring
  `test/support/live_ws_process_pg.rb`.
- **Seam E — scaffolding**: `monk new --jobs` output, as `scaffold_test.rb`
  does for the other flags.

## Phase 0 — Spikes (throwaway, results recorded here)

Nothing here is kept as code. Each result either confirms a decision
above or changes it before Phase 1.

1. **Claim latency under a backlog, measured to check ADR 0013.** Same Postgres 16,
   8 worker Ractors, backlogs of 10k / 100k / 1M ready jobs plus 100k
   scheduled rows. Compare the six-table claim with a carefully built single-table claim
   (`UPDATE … WHERE id = (SELECT … FOR UPDATE SKIP LOCKED)` with a partial
   index). Record p50/p99 claim time and dead-row counts after a sustained
   run. If the single table is not measurably worse, ADR 0013 is reopened
   before anything is built.
2. **No double claims across Ractors**: 8 Ractors × 10k jobs, each claim
   logged; every job id is claimed exactly once.
3. **Per-job timeouts inside a worker Ractor.** Does `Timeout.timeout`
   work in a non-main Ractor on 4.0.6? If not, v1 ships without per-job
   timeouts and says so (a stuck job holds its worker until the process is
   restarted).
4. **Stopping worker Ractors cleanly**: `Signal.trap` in the main Ractor
   sends `:stop` to each worker's port; a worker finishes its current job
   and exits; `Ractor#join`/`#value` reports it. Also: what a worker
   Ractor dying from an uncaught exception looks like to the supervisor,
   so that it can respawn the worker.

## Phase 1 — Schema

1. `create_jobs_tables.up.sql` / `.down.sql` with the six tables and their
   indexes, as plain SQL for `Migrator` (`docs/history/plan-migrations.md`).
   The canonical copy lives in `lib/monk/templates/jobs/db/migrate/`, so
   the scaffold and the test suite apply the same file.
2. Test: `Migrator` applies and rolls back the pair cleanly against the
   test database. The foreign keys from each execution table to
   `monk_jobs` use `ON DELETE CASCADE`, so deleting a finished job cleans
   up after itself.

## Phase 2 — `Monk::Job` and the registry (Seam A)

3. `Monk::Job` base class. `inherited` records the subclass in
   `Monk::Jobs`' registry (main Ractor, at load time). Class-level
   settings: `queue "mailers"`, `priority 10`, `max_attempts 3`.
4. JSON-only argument check, with an error that names the offending
   argument and its class.
5. `Monk::Jobs.freeze_registry!` via `Monk.freeze_hooks`. Test: after
   `Monk.freeze!`, a worker Ractor resolves `"SendReceipt"` to the class
   and calls `.perform`. Before it, the same attempt fails with a Monk
   error naming the fix (ADR 0003 posture), not an opaque
   `Ractor::IsolationError`.

## Phase 3 — Postgres adapter: enqueue, claim, finish (Seam B)

6. `enqueue`: inserts into `monk_jobs` plus `monk_ready_executions`, or
   `monk_scheduled_executions` when `run_at`/`wait:` is in the future, in
   one transaction. Takes `conn:` (Decision 9). Test: enqueue inside a
   rolled-back app transaction leaves no job behind.
7. `claim`: Decision 2's query. Test: two connections claiming at the
   same time never get the same job.
8. `finish`: deletes the claimed row and the job in one transaction.

## Phase 4 — Failures, retries, scheduled jobs (Seam B)

9. `fail(job_id, error, retry_at:)`: from claimed to scheduled, or to
   failed once `attempts` reaches `max_attempts`. The error class, message
   and the first lines of the backtrace are stored, truncated.
10. `promote_due(limit)`: moves due scheduled rows to ready in one batch,
    using `SKIP LOCKED` so two dispatchers can't collide.
11. `retry_failed(job_id)`, `discard_failed(job_id)`.

## Phase 5 — In-memory adapter (Seam B, second implementation)

12. The same contract, backed by one queue Ractor (the `StateRactor`
    pattern). Passes the shared adapter suite.
13. `Monk::Jobs.drain!`: runs ready jobs synchronously in the calling
    Ractor until the queue is empty, and fails loudly if a job raises. It
    is the default in `MONK_ENV=test`, so an app's tests can assert on the
    effects of enqueued jobs without starting a worker process.

## Phase 6 — Ractor runtime (Seams C and D)

14. `Monk::Jobs::Runtime.new(queues:, workers:, poll_interval:,
    dispatch_interval:).run`: the main Ractor registers a
    `monk_processes` row, spawns the dispatcher and the workers, then
    loops on heartbeat and prune.
15. Worker loop: claim → look up the class → `perform(*args)` →
    `finish`, or `fail` with backoff. Anything a job raises is rescued
    inside the worker, so one bad job never kills the Ractor. A Ractor
    that dies anyway is respawned by the supervisor (Phase 0.4).
16. Pruning: processes whose heartbeat is older than the threshold have
    their claims moved back to ready (Decision 4) and their row
    deleted.
17. Graceful stop on `TERM`/`INT`: stop claiming, wait up to
    `shutdown_timeout` for jobs in flight, release whatever is still
    claimed back to ready, delete the process row.
18. Seam D: a real child process. Enqueued jobs run. `kill -9` of the
    child, followed by a second process pruning it, re-runs the orphaned
    job exactly once. `TERM` finishes the job in flight and leaves nothing
    claimed.

## Phase 7 — Optional `NOTIFY` wake-up

19. `Monk::Jobs.configure(notify: true)`: `enqueue` adds `pg_notify`
    in the same transaction, and a listener Ractor in the job process
    (the `PgFanout` subscriber loop) wakes idle workers early. Polling
    keeps running regardless. Documented as for low-to-moderate write
    volume only, with ADR 0013's commit-lock caveat.

## Phase 8 — Scaffolding: `monk new --jobs` (Seam E)

20. `--jobs` implies `--postgres` (`@postgres = postgres || auth ||
    jobs`) and nothing else. It works with or without
    `--auth`/`--mail`/`--live`/`--redis`.
21. Files:
    - `config/jobs.rb`: `Monk::Jobs.configure(db_name: :primary, …)`
      plus requires for `jobs/*.rb`.
    - `jobs/hello_job.rb`: a demo job logging through `Monk::Log`.
    - `bin/jobs`: loads settings, persistence, the app's jobs and the
      views, calls `Monk.freeze!`, then `Monk::Jobs::Runtime.new(…).run`.
    - `db/migrate/00000000000002_create_jobs_tables.{up,down}.sql`.
      Version 2 so it sorts after auth's `…01` when both are present;
      it's harmless without auth.
22. Wiring: `config.ru` requires `config/jobs`, so routes can enqueue.
    A demo route (e.g. `POST /hello/job`) enqueues `HelloJob` so the
    scaffold shows the round trip end to end.
23. `.env`/`.env.test`: `JOBS_WORKERS`, `JOBS_QUEUES`. `SETUP.md` gains a
    "Background jobs" section (run `bin/migrate`, then `bin/jobs` beside
    `bin/server`). `exe/monk` usage and help text mention `--jobs`.
24. Dockerfile and `docs/guides/deploying.md`: the job process is a
    second command on the same image, like `bin/websocket_server`.
25. Retrofitting an existing app: the guide lists the files to copy and
    the migration to add. Whether Monk should also ship a `monk jobs:install`-style
    command is out of scope (see below).

## Phase 9 — Docs

26. `docs/guides/jobs.md`: defining a job, enqueueing it (with and
    without `conn:`), idempotency first, retries and failed jobs,
    scheduling, running `bin/jobs`, sizing workers, the test adapter.
27. README features table, `CONTEXT.md` vocabulary (**Job**, **Queue**,
    **Ready / scheduled / claimed / failed execution**, **Dispatcher**,
    **Job process**), CHANGELOG.

## Phase 10 — `Monk::Mail` integration — DECISION NEEDED, analyzed together once Phases 1–9 ship

The goal: when an app has jobs, mail is delivered from a job rather than
blocking the worker Ractor that serves the request. ADR 0012 accepted
synchronous sends explicitly because "Monk has no job queue", and this
plan removes that premise. The integration is deliberately deferred to
the end, so it's designed against the real `Monk::Jobs` API instead of a
guessed one. These are the questions to settle together at that point,
not decisions:

- **What API.** Candidates:
  - (a) An explicit `Monk::Mail.deliver_later(...)`, with the same
    arguments as `deliver`, that enqueues a built-in
    `Monk::Mail::DeliveryJob`.
  - (b) `deliver` itself becoming asynchronous whenever jobs are
    configured. Likely rejected, since the same call would behave
    differently depending on another feature's presence.
  - (c) Leaving `Monk::Mail` alone and having only the scaffold's
    `config/auth.rb` (`AppMailer::DELIVER`) enqueue a job when `--jobs`
    was passed.
- **Where rendering happens.** Rendering at enqueue time stores finished
  HTML in `args` (bigger rows, but the job needs no views). Rendering in
  the job means `bin/jobs` must compile and freeze the app's views, which
  Phase 8 already plans, and `args` stays small.
- **Secrets in the job table.** A magic link carries a raw login token,
  and `Monk::Auth` stores only its hash precisely so the database never
  holds a usable one. Putting the link in `monk_jobs.args` undoes that
  for the job's lifetime, and for longer in failed jobs. Options: accept
  it with delete-on-finish and a short `max_attempts`; encrypt args with
  `AUTH_SECRET`; or keep magic links synchronous and make everything else
  asynchronous.
- **Latency for a user who is waiting.** A login link waits for the poll
  interval plus the queue ahead of it. Candidates: a dedicated
  `mailers` queue with its own worker and priority, or `notify: true` for
  that queue only.
- **Which failures to retry.** `DeliveryError` (the relay is unreachable
  or rejected the send) is worth retrying. `InvalidMessageError` never
  is, and should go straight to failed.
- **Scaffolding.** What `monk new --auth --jobs` (and `--mail --jobs`)
  generate. `config/auth.rb` probably gets a jobs-aware variant.
- **Records to update**: ADR 0012's "Monk has no job queue" paragraph,
  and `docs/guides/mail.md` / `auth.md`.

## Explicitly out of scope for this plan

- Recurring (cron) jobs, concurrency limits, pausing queues, batches.
  Each is a later table that doesn't change the claim path (ADR 0013).
- Keeping finished jobs, and any dashboard or web UI.
- A Redis adapter.
- Threads inside a worker Ractor (more than one job at a time per Ractor
  for IO-bound work). v1 runs one job per worker Ractor; revisit if mail
  delivery (Phase 10) shows the need.
- A `monk jobs:install` retrofit command.
- Running job workers inside the web server's process.

## Risks worth watching

- **Gems that job code calls.** Job code runs in a worker Ractor, so
  every gem it touches has to survive there: module ivars, class
  variables and `define_method` blocks all fail (`docs/design/ractor.md`,
  ADR 0012's `mail` gem finding). The guide has to say this plainly,
  because a job that works in `drain!` (main Ractor) can fail in
  `bin/jobs`. Worth deciding whether `drain!` should run jobs inside a
  throwaway Ractor so that tests catch it.
- **No per-job timeout** if Phase 0.3 fails, so a hung job holds a
  worker indefinitely. The heartbeat keeps its process alive, so pruning
  won't rescue it either.
- **At-least-once delivery surprising apps** that send non-idempotent
  side effects (charges, emails). This is the main reason Phase 10's mail
  design needs care.
- **Phase 0.1 contradicting ADR 0013.** If it does, the storage design
  changes before Phase 1, not after.
- **Postgres restart or failover** while `bin/jobs` runs. Like
  `PgFanout` (`plan-live-pg-fanout.md` Phase 4 step 13), v1 may simply
  let the affected Ractor die. The supervisor respawning it (Phase 6.15)
  is the first line of defense, and needs its own test.
