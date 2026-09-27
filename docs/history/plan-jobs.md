# Monk::Jobs — background jobs on Postgres — implementation plan

> **Historical document.** It records how this was planned or built at the time and may describe things that have since changed or shipped. For how Monk works today, see [`docs/guides/`](../guides/).

Branch: `main_dev/monk_jobs`. Phases 0 (spikes), 1 (schema), 2 (job
class and registry), 3 (Postgres enqueue/claim/finish), 4 (failures,
retries, scheduled jobs), 5 (`drain!` and `clear!` for tests), 6 (the
Ractor runtime) and 8 (`monk new --jobs`) done by 2026-09-27; Phase 7
(`NOTIFY` wake-up) skipped; nothing from Phase 9 on is implemented yet.
Companion record: [`../adr/0013-jobs-narrow-state-table-plus-payloads.md`](../adr/0013-jobs-narrow-state-table-plus-payloads.md)
(why the queue is a narrow state table plus a payload table, why workers
poll, and why no existing gem fits). The ADR's first version chose
Solid Queue's six-table split; Phase 0's measurements changed that, see
the results below.

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
`Monk::Persistence::Pg`, the same posture as `Monk::Auth`. Monk takes on
no runtime dependency.

Proposed layout (to be confirmed as phases land):

```
lib/monk/jobs.rb                 # configure, enqueue, freeze_registry!
lib/monk/jobs/job.rb             # Monk::Job base class + class registry
lib/monk/jobs/errors.rb
lib/monk/jobs/adapters/pg.rb     # monk_jobs + monk_job_payloads + monk_processes
lib/monk/jobs/runtime.rb         # supervisor (main Ractor: stager, heartbeat, prune) and worker Ractors
```

## Decisions locked in before Phase 1

The storage design is ADR 0013. The rest are recommendations from the
same analysis, turned into plan assumptions here. Reversing one
invalidates the phases that depend on it.

1. **Three tables** (ADR 0013):
   - `monk_jobs`, narrow: `id` (identity), `queue`, `priority` (smallint,
     lower runs sooner), `state` (`available`/`scheduled`/`running`/`failed`,
     with a CHECK), `run_at`, `attempts`, `max_attempts`, `locked_by`,
     `locked_at`. Partial indexes: `(queue, priority, run_at, id) WHERE
     state = 'available'`, `(run_at) WHERE state = 'scheduled'`,
     `(locked_by) WHERE state = 'running'`.
   - `monk_job_payloads`: `job_id` (PK, FK to `monk_jobs` `ON DELETE
     CASCADE`), `job_class`, `args jsonb`, `last_error`, `created_at`.
     Written once at enqueue, deleted with its job, updated only to record
     an error.
   - `monk_processes`: `id`, `hostname`, `pid`, `started_at`,
     `last_heartbeat_at`, one row per `bin/jobs` process.
   The migration also sets per-table autovacuum settings on `monk_jobs`
   (e.g. `autovacuum_vacuum_scale_factor = 0.01`,
   `autovacuum_vacuum_cost_delay = 0`). These follow Solid Queue guides'
   advice and were not measured here.
2. **Claiming a job** is one statement: `WITH c AS (UPDATE monk_jobs SET
   state = 'running', locked_by = $1, locked_at = now(), attempts =
   attempts + 1 WHERE id = (SELECT id … WHERE queue = $2 AND state =
   'available' ORDER BY priority, run_at, id FOR UPDATE SKIP LOCKED LIMIT
   1) RETURNING …) SELECT … FROM monk_job_payloads JOIN c`. A worker
   serving several queues runs one claim per queue, in the configured
   order (strict ordering across queues, as in Solid Queue); a single
   `queue = ANY(...)` query can't use the index order across queues. One
   job per worker Ractor in v1.
3. **Workers poll**, with a short, configurable interval. `LISTEN`/`NOTIFY`
   is never how jobs are delivered (ADR 0013), and v1 doesn't use it
   to wake workers either (Phase 7, skipped). Lower `poll_interval` is
   how an app gets faster pickup.
4. **Delivery is at-least-once.** `running` jobs of a process whose
   heartbeat has expired go back to `available`, with `attempts` already
   counted. Jobs must be idempotent, and the guide
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
   1). Its main Ractor is the supervisor. It handles signals, and on a
   ~1 s tick runs the stager (flips due `scheduled` jobs to `available`,
   in batches with `SKIP LOCKED`, so several job processes can all run
   it), the heartbeat and pruning. There's no dispatcher Ractor. It runs
   N worker Ractors, and each Ractor, the supervisor included, opens
   its own `PG::Connection` through `Monk::Persistence::Pg`'s per-Ractor
   registry. Monk does not run job workers inside Kino's process.
9. **Enqueueing is a plain insert on the caller's connection.** By
   default `enqueue` does its own `Monk::Persistence::Pg.checkout`. An
   explicit `conn:` argument makes it run on a connection the caller
   already holds, inside that caller's transaction. That's required, not
   optional sugar: `checkout` is a `SizedQueue(1)` per Ractor, so a nested
   `checkout` inside an open one would wait until it timed out.
10. **Retries are owned by the queue.** A job that raises is set to
    `state = 'scheduled'` with `run_at = now() + backoff` (`attempts ** 4
    + 15` seconds, Sidekiq-shaped, to be confirmed), and its error goes in
    `monk_job_payloads.last_error`, until `max_attempts` (default 5). After
    that it's set to `state = 'failed'` and stays in `monk_jobs`, outside
    every hot index. `Monk::Jobs.retry_failed(job_id)` sets it back to
    `available`. `discard_failed` deletes it.
11. **One adapter, behind an interface**: `enqueue`, `claim(queue,
    process_id)`, `finish`, `fail(error:, retry_in:)`, `stage_due(limit)`,
    `register_process`, `heartbeat`, `prune(threshold)`, `retry_failed`,
    `discard_failed`, `clear!`. Postgres only, for real use and for tests
    alike: an app's tests enqueue on its test database, run the jobs with
    `Monk::Jobs.drain!` and empty the queue with `Monk::Jobs.clear!`.
    `Monk::Jobs` only talks to the adapter through these operations, so
    another adapter (Redis, in-memory) could still be added if a real
    need appears. An in-memory adapter was built in Phase 5 and dropped;
    see there for why.
12. **Scaffolding**: `monk new --jobs` implies `--postgres`, the same way
    `--auth` does (Phase 8).
13. **The queue uses the app's database by default** (`db_name:
    :primary`), so `enqueue(conn:)` can commit together with the app's own
    writes. A separate database (`db_name: :queue`, registered like any
    other) is documented as the step to take once the app has long
    transactions or heavy load. It isolates the queue from the app's long
    transactions (Phase 0), but enqueue then happens after the app's
    commit, and a crash in between can lose the job.

## Seams

- **Seam A — `Monk::Job` and the class registry**, no database: arguments are
  checked when a job is enqueued, the registry is sealed at `Boot`, and a job class is reachable
  from a worker Ractor after `Monk.freeze!`.
- **Seam B — the adapter's operations**, against the real test
  database, no Ractor runtime involved.
- **Seam C — the Ractor runtime in one process**: the supervisor (with
  the stager, heartbeat and pruning) and worker Ractors against the
  Postgres adapter; concurrency and failure handling.
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

### Phase 0 results — DONE 2026-09-26

Ran against a throwaway `postgres:16` (16.15) container on port 55432, not
the shared development database. Ruby 4.0.6, `pg` 1.6.3, `timeout` 0.6.0,
8 worker Ractors, each with its own `PG::Connection`. Scripts and raw
output are not committed (throwaway).

**0.1 — Claim latency. Three rounds, and they changed ADR 0013's
decision** from Solid Queue's six tables to a narrow state table plus a
payload table (2b below). First round, three schemas:
`multi` (the six-table claim), `single_careful` (partial index on
`(queue, priority, run_at, id) WHERE locked_at IS NULL`, `ORDER BY
priority, run_at, id`, delete on finish) and `single_retain`
(GoodJob-like: finished rows kept via `UPDATE finished_at`).

*Draining a backlog, nothing arriving, small args, 40k claims.* Median
claim time in ms, first 10% → last 10% of the run:

| Backlog (+100k scheduled) | Long tx | multi | single_careful | single_retain |
|---|---|---|---|---|
| 10k | no | 0.95 → 0.96 | 0.97 → 0.93 | 0.87 → 0.91 |
| 100k | no | 0.94 → 1.11 | 1.03 → 1.04 | 0.90 → 1.10 |
| 1M | no | 0.91 → 0.96 | 0.88 → 1.06 | 0.89 → 1.05 |
| 10k | yes | 1.11 → 1.34 | 1.00 → 1.55 | 0.93 → 2.16 |
| 100k | yes | 1.06 → 3.93 | 1.08 → 4.87 | 1.20 → 4.86 |
| 1M | yes | 1.08 → 3.66 | 1.18 → 5.01 | 1.14 → 4.90 |

*Steady load, 150 s:* a producer enqueues about 1,200 jobs/s, 8 workers
claim and finish, args ~1 KB, starting from 100k ready + 100k scheduled
jobs:

| | Long tx | Median claim, first → last 15 s (ms) | Jobs/s | WAL per job | Dead tuples, hot table | Hot indexes |
|---|---|---|---|---|---|---|
| multi | no | 1.02 → 1.08 | 1,979 | 0.99 KB | 2,928 | 8.5 MB |
| single_careful | no | 1.16 → 1.01 | 1,954 | 1.46 KB | 98,750 | 25 MB |
| multi | yes | 2.36 → 12.05 | 897 | 1.17 KB | 134,906 | 17 MB |
| single_careful | yes | 3.49 → 25.79 | 545 | 1.60 KB | 162,818 | 38 MB |

What this shows:

- **A long backlog on its own costs nothing in either design.** Taking the
  head of a B-tree is as fast at 1M rows as at 10k. Ordering by `run_at`
  keeps scheduled rows out of the way in the single table too, as long as
  there is only one priority (see 0.1c). The ADR's first version had
  "dequeue cost grows with the whole table" and "scheduled rows pollute
  the hot index" as the mechanism. Neither was reproduced for a carefully
  built single table (the advisory-lock CTE, GoodJob's default and the
  source of its 100k+ warning, was not benchmarked; it isn't an option
  for Monk).
- **The difference appears under sustained churn**, and most of all when
  vacuum is held back. With a long transaction open, `single_careful` ended twice
  as slow as `multi` (25.8 against 12.1 ms) and processed 40% fewer jobs.
  Without one, latency and throughput matched, but `multi` wrote 32% less
  WAL per job and left 34x fewer dead tuples in its hot table (dead-tuple
  counts are a single snapshot that depends on when autovacuum last ran,
  and varied a lot between sessions; later rounds leave them out). That's
  the wide-row `UPDATE` on claim.
- **Neither design is immune to a long transaction.** `multi`'s median also rose
  about 5x in 150 s, because deleted rows pile up at the head of the ready
  index and can't be vacuumed while an old snapshot is held. Consequence
  for the guide (Phase 9): recommend `idle_in_transaction_session_timeout`,
  and name long-running transactions on the same database as the main
  operational risk for the queue.

**0.1b — A separate database isolates the queue from long transactions.**
Postgres only holds back cleanup of an ordinary table for transactions in
that table's database. Same 150 s steady load, with the long transaction
held in a second database (`app_other`) on the same server:

| | Long tx in | Median claim, first → last 15 s (ms) | Jobs/s |
|---|---|---|---|
| multi | other DB | 1.02 → 1.14 | 1,923 |
| single_careful | other DB | 1.16 → 0.97 | 1,931 |

Both behave as if there were no long transaction. That's why Rails 8 gives
Solid Queue its own database by default, and it's the basis for Decision 13.
It doesn't help against a long transaction inside the queue's own
database, or against holders that span the whole server (replication
slots, `hot_standby_feedback`).

**0.1c — A narrow table plus payloads (option 2), and why it needs a
`state` column.** Two more candidates:
- `narrow` (2a): `n_jobs` holds only scheduling columns, with a partial
  index `(queue, priority, run_at, id) WHERE locked_at IS NULL`, and
  `n_payloads` holds `job_class`/`args`.
- `2b`: exactly Decision 1's tables and indexes, with a `state` column,
  and a stager running its promotion query every second.

Same 150 s steady load, all rows below from one session so they compare
directly (WAL per job only compared in the healthy runs, where every
schema processed about the same number of jobs):

| | Long tx | Median claim, first → last 15 s (ms) | Jobs/s | WAL per job |
|---|---|---|---|---|
| 2b | no | 1.19 → 0.99 | 1,960 | 1.08 KB |
| narrow (2a) | no | 1.09 → 0.91 | 1,970 | 0.90 KB |
| multi | no | 1.05 → 0.97 | 1,990 | 1.12 KB |
| single_careful | no | 1.09 → 0.89 | 1,951 | 1.39 KB |
| 2b | same DB | 2.28 → 12.82 | 917 | — |
| narrow (2a) | same DB | 2.51 → 14.48 | 852 | — |
| multi | same DB | 2.21 → 11.20 | 927 | — |
| single_careful | same DB | 3.26 → 26.61 | 547 | — |
| 2b | other DB | 1.04 → 1.00 | 1,986 | 1.13 KB |
| narrow (2a) | other DB | 1.08 → 0.90 | 1,967 | 1.06 KB |

With vacuum keeping up, all four are the same apart from WAL. Narrow rows
write less than a wide one; 2b writes a little more than 2a because a
claim also adds an entry to the `running` index. With vacuum held back,
2b stays within about 1% of multi's throughput and 15% of its latency, and
does about twice as well as the wide single table.

2a looked equally good with one priority, but it breaks with several.
With 100k future jobs at priority 0 and 50k ready jobs at priority 10,
2a claimed at 5.48 ms (p99 14.2 ms), reading 606 buffers per claim,
because every claim stepped over the future rows sorted ahead of it in
the index. 2b, with only `available` rows in its claim index, claimed
the same data at 0.96 ms (p99 5.1 ms), reading 4 buffers.

*2b draining a backlog* (the first round's test, rerun for 2b with multi
alongside as a reference in the same container, since the first round's
container was gone). Median claim time in ms, first 10% → last 10% of the
claims, then over the whole run with throughput:

| Backlog (+100k scheduled) | Long tx | 2b | multi | 2b, whole run | multi, whole run |
|---|---|---|---|---|---|
| 10k (8k claims) | no | 1.16 → 0.92 | 0.99 → 0.87 | 0.99 ms, 3,703/s | 0.92 ms, 3,963/s |
| 100k (40k claims) | no | 0.92 → 1.04 | 0.93 → 0.99 | 1.01 ms, 3,809/s | 0.98 ms, 3,559/s |
| 1M (40k claims) | no | 0.98 → 1.13 | 0.96 → 1.08 | 1.04 ms, 3,577/s | 1.07 ms, 3,279/s |
| 10k | same DB | 0.91 → 1.54 | 0.96 → 1.42 | 1.31 ms, 2,991/s | 1.22 ms, 3,429/s |
| 100k | same DB | 1.13 → 3.90 | 1.17 → 3.77 | 2.65 ms, 1,871/s | 2.59 ms, 1,724/s |
| 1M | same DB | 1.20 → 4.21 | 1.08 → 3.78 | 2.71 ms, 1,528/s | 2.82 ms, 1,463/s |

Backlog size doesn't matter for 2b either, and in these shorter runs it
tracks multi closely in every row, including with the long transaction.

**Decision (2026-09-26): 2b**, recorded in ADR 0013, which was rewritten
from its first, six-table version. multi is the runner-up: slightly better
only while vacuum is held back in the same database, at the price of a
dispatcher, twice the tables and state moves spread across tables.

**0.2 — No double claims, none lost.** Across every benchmark run (the
first round's 22 runs, about 600k claims; 10 steady-load runs that
logged every claimed id, about 2.3M claims; 2b's 13 draining runs, about
430k claims; all with 8 concurrent Ractors), zero duplicate claims. In a full
drain of 80,000 jobs, both `multi` and `single_careful` claimed exactly
80,000 distinct ids, and so did `2b` in its own full drain. Afterwards
`multi`'s ready and claimed tables were empty, and so were `2b`'s
`monk_jobs` and `monk_job_payloads` (no job left `running`, no orphaned
payload).

**0.3 — `Timeout.timeout` works inside a worker Ractor, with one catch
for database work.** It fires correctly on a sleeping job, a CPU-bound
loop (0.41 s against a 0.3 s limit), a socket read that never returns,
and in 4 Ractors at once. But when it interrupts a query, pg does not
cancel the query on the server. The next query on that connection waited
4.5 s for an abandoned `pg_sleep(5)` to finish. The connection was
usable afterwards, including `ROLLBACK` of an interrupted transaction.
`statement_timeout` raises `PG::QueryCanceled` and leaves the connection
immediately usable. Consequence for Phase 6: per-job timeouts ship in v1.
After a `Timeout::Error` the worker must `cancel` or `reset` its
connection before claiming again. A per-connection `statement_timeout` is
the recommended companion for database-heavy jobs.

**0.4 — Supervisor, stop, respawn: works, with one correction to the
expected API.** `Ractor#monitor(port)` delivers only a bare Symbol
(`:exited` / `:aborted`) that doesn't say which Ractor it's about, so
the supervisor needs **one monitor port per worker** (a Hash from port to
worker). A worker that died from an uncaught exception reports
`:aborted`, and its `#value` raises `Ractor::RemoteError` with the
original exception as `#cause`. The supervisor respawned it and the new
worker picked up jobs. On `TERM` (trapped in the main Ractor), each
worker got `:stop` on its own control port, finished the job in flight,
and exited; the supervisor exited cleanly. Ruby 4.0's `Ractor::Port` has
no non-blocking receive, so "stop between jobs" is a `Ractor.select`
over the control port and a timer port, one of which is what the worker
loop waits on when idle.

**Found along the way:** SQL kept in heredoc constants isn't shareable
(`Ractor::IsolationError: can not access non-shareable objects in
constant … by non-main Ractor`, from the benchmark's own producer
Ractor). The Postgres adapter must `Ractor.make_shareable` every SQL
constant, the same hazard `docs/design/ractor.md` records for
`lib/monk/assets.rb`.

## Phase 1 — Schema — DONE 2026-09-26

`lib/monk/templates/jobs/db/migrate/00000000000002_create_jobs_tables.{up,down}.sql`,
tests in `test/jobs_schema_test.rb` (7 tests), applied through the real
`Migrator` straight from the template directory. Full suite green (605
runs, 0 failures), RuboCop clean.

1. `create_jobs_tables.up.sql` / `.down.sql` with Decision 1's three
   tables, their partial indexes, the `state` CHECK and the per-table
   autovacuum settings, as plain SQL for `Migrator`
   (`docs/history/plan-migrations.md`). The canonical copy lives in
   `lib/monk/templates/jobs/db/migrate/`, so the scaffold and the test
   suite apply the same file.
2. Test: `Migrator` applies and rolls back the pair cleanly against the
   test database. Deleting a job deletes its payload (`ON DELETE
   CASCADE`), and an unknown `state` is rejected by the CHECK.

## Phase 2 — `Monk::Job` and the registry (Seam A) — DONE 2026-09-26

`lib/monk/jobs.rb` (registry, freeze hook), `lib/monk/jobs/job.rb`,
`lib/monk/jobs/args.rb`, `lib/monk/jobs/errors.rb`; tests in
`test/jobs_job_test.rb` (17) and `test/jobs_args_test.rb` (8).

**Differences from the steps below, found while building:**

- `inherited` only *records* the subclass. Names are resolved when the
  registry is frozen, so `Foo = Class.new(Monk::Job)` (named after it's
  created) is still found. Anonymous classes are skipped, since a job
  without a name can never be found again once enqueued. Phase 3's
  `enqueue` should reject one up front.
- `Monk::Jobs.lookup` reads nothing but the frozen registry, which is
  `nil` before the first freeze. `nil` is shareable, so a worker Ractor
  gets `NotFrozenError` naming the fix rather than a
  `Ractor::IsolationError`, with no rescue needed.
- Only recorded job classes are ever returned: `lookup("File")` or
  `lookup("Monk::Job")` is `UnknownJobError`, never `Object.const_get`.
- Settings are inherited from the superclass, so an app can put shared
  ones on its own base class. `priority` and `max_attempts` are checked
  against the SMALLINT columns when set.
- `Args.check!` names the offending value by its full path
  (`args[0]["user"]["joined"]`). Symbol keys and non-finite Floats are
  rejected, because JSON would hand `#perform` back something different.

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

## Phase 3 — Postgres adapter: enqueue, claim, finish (Seam B) — DONE 2026-09-26

`lib/monk/jobs/adapters/pg.rb`, `lib/monk/jobs/claim.rb`,
`Monk::Jobs.configure`/`.adapter`/`.enqueue` in `lib/monk/jobs.rb`,
`Monk::Job.enqueue`; tests in `test/jobs_pg_adapter_test.rb` (23),
including enqueue from a worker Ractor after `Monk.freeze!` and 8 worker
Ractors draining 200 jobs with none claimed twice.

**Differences from the steps below, found while building:**

- `Monk::Jobs.configure(db_name:)` builds the adapter, which freezes
  itself and holds only the Symbol, so it's shareable from the moment
  it's created. Enqueue from a route handler needs no extra freezing
  beyond `Monk::Persistence::Pg`'s own.
- `enqueue` takes only `wait:`/`at:`/`conn:`. Queue, priority and
  `max_attempts` come from the job class, with no per-call overrides in
  v1. The database clock sets `run_at` and whether the job starts
  `scheduled` or `available`, so an app server's clock can't make a job
  due early.
- `finish(id, process_id)` deletes only a job the process still holds
  (`state = 'running' AND locked_by = process_id`), and returns whether
  it did. A job pruned from a dead process and claimed again elsewhere
  isn't deleted by its first worker finishing late.
- **Found and fixed on the way: pg 1.6.3 couldn't decode `json`/`jsonb`
  with json 3.0.2.** Its JSON decoder passes `quirks_mode:` to
  `JSON.parse`, a keyword json 3 no longer accepts, so every
  `json`/`jsonb` column read through a `Monk::Persistence::Pg`
  connection raised `ArgumentError`, app models included. Fixed on its
  own, outside this plan: `Monk::Persistence::Pg` now installs its own
  JSON decoder (`test/persistence_pg_json_test.rb`, CHANGELOG
  "Unreleased"). The adapter still selects `args::text` and parses it
  itself, so a claim decodes the same on any connection an app passes
  as `conn:`.

6. `enqueue`: one statement inserting into `monk_jobs` (`state =
   'available'`, or `'scheduled'` with a future `run_at` for `wait:`/`at:`)
   and `monk_job_payloads`. Takes `conn:` (Decision 9). Test: enqueue
   inside a rolled-back app transaction leaves no job behind.
7. `claim`: Decision 2's query, one queue at a time. Tests: two
   connections claiming at the same time never get the same job; a lower
   `priority` number is claimed first; `scheduled` and `failed` jobs are
   never claimed.
8. `finish`: `DELETE FROM monk_jobs` for the job; the payload goes by
   cascade.

## Phase 4 — Failures, retries, scheduled jobs (Seam B) — DONE 2026-09-26

`fail`, `stage_due`, `retry_failed`, `discard_failed` in
`lib/monk/jobs/adapters/pg.rb`; `Monk::Jobs.retry_failed`/`.discard_failed`,
`.backoff`, `.describe_error` in `lib/monk/jobs.rb`; tests in
`test/jobs_pg_failures_test.rb` (13, including 4 stager Ractors moving
200 due jobs exactly once) and `test/jobs_retry_policy_test.rb` (4). The
Postgres test setup moved into a shared `JobsTestHelpers` in
`test/test_helper.rb`.

**Differences from the steps below, found while building:**

- `fail(id, process_id, error:, retry_in:)` is one statement, and like
  `finish` only acts while the process still holds the job. The database
  decides where the job goes (`scheduled`, or `failed` once `attempts`
  has reached `max_attempts`), so the runtime doesn't need to know
  `max_attempts`. `retry_in: nil` fails the job straight away, for errors
  never worth retrying (Decision 7's unknown job class, Phase 10's
  invalid messages). It returns `:scheduled`, `:failed`, or `nil` when
  the process no longer held the job.
- The retry policy lives in `Monk::Jobs`, shared by both adapters:
  `backoff(attempts)` is `attempts ** 4 + 15` seconds, without Sidekiq's
  random jitter. Open point: without jitter, a batch of jobs that failed
  together (say the SMTP relay was down) all retry together.
  `describe_error` keeps the class, message and first 10 backtrace lines,
  capped at 4,000 characters.
- A retried job keeps its `last_error` until it succeeds or is
  discarded. `retry_failed` resets `attempts` and sets `run_at = now()`,
  so it queues behind jobs that were already waiting.

9. `fail(job_id, error, retry_at:)`: `running` to `scheduled`, or to
   `failed` once `attempts` reaches `max_attempts`, clearing the lock
   columns. The error class, message and the first lines of the backtrace
   go in `monk_job_payloads.last_error`, truncated.
10. `stage_due(limit)`: flips due `scheduled` rows to `available` in one
    batch, using `SKIP LOCKED` so two job processes staging at once can't
    collide. Test: a job enqueued with `wait:` becomes claimable only
    after its `run_at` and a stage.
11. `retry_failed(job_id)` (`failed` to `available`, `attempts` reset),
    `discard_failed(job_id)` (delete).

## Phase 5 — Testing an app's jobs: `drain!` and `clear!` — DONE 2026-09-26

Originally "In-memory adapter (Seam B, second implementation)". Built as
planned, then dropped before commit. `Monk::Jobs.drain!` and
`Monk::Jobs.clear!` in `lib/monk/jobs.rb`, `clear!` in the Postgres
adapter; tests in `test/jobs_drain_test.rb` (10), plus two timing and
ordering tests added to `test/jobs_pg_failures_test.rb`.

**Why the in-memory adapter was dropped.** It was meant for tests, and
the Postgres queue turned out to be the better test double:

- Every app with jobs already has Postgres (`--jobs` implies
  `--postgres`), and its tests already run a test database.
- The memory adapter ignores `conn:`, since it has no transaction to
  join. A job enqueued inside a transaction that rolls back would still
  exist and run in tests, but not in production. That's a behaviour gap
  that can hide a real bug, and no shared contract can close it.
- `drain!` works on Postgres, and a claim costs about 1 ms, so speed
  isn't a reason.
- It was about 150 lines, and a second implementation of every
  operation, which Phase 6's process registration, heartbeat and pruning
  would have had to extend too.

While it existed, a shared contract suite ran the same 19 tests against
both adapters. Postgres passed all of it apart from the then-new
`drain!`. The tests that added coverage beyond Phases 3 and 4 were kept
as Postgres tests: `drain!`, the retry path by the clock, and a retried
job queueing behind jobs already waiting.

**What was kept, and what was found building it:**

- **`drain!` runs each job in a throwaway Ractor by default**, as
  `bin/jobs` will, so an app's tests catch a job that only works in the
  main Ractor. This resolves the risk listed below.
  `drain!(in_ractor: false)` runs jobs in the calling Ractor, for tests
  that need to see a job's side effects there. `drain!` calls
  `Monk.freeze!` first, as `bin/jobs` will. Each job Ractor that touches
  the database opens its own connection, which is closed when that
  Ractor is garbage-collected.
- `drain!` stages due jobs, then claims from the queues of every recorded
  job class plus `"default"`, until none is left. That includes jobs
  enqueued by the jobs it runs. Jobs not yet due are left. Nothing is
  retried: the first job that raises is marked `failed` and its error
  re-raised as the job's own error, not a `Ractor::RemoteError`.
  Re-raising it needs `raise e.cause, cause: nil`; without `cause: nil`,
  Ruby chains the `RemoteError` onto it and raises `ArgumentError:
  circular causes`.
- **`NotImplementedError` needs catching explicitly.** A job class
  without `self.perform` raises it, and it is a `ScriptError`, not a
  `StandardError`, so `rescue StandardError` misses it and the job would
  stay `running`. `drain!` catches it, and Phase 6's worker loop must
  too.
- **`Monk::Jobs.clear!`** empties the queue (every job, failed ones
  included, and every process row) between an app's tests. It raises
  `ClearOutsideTestsError` unless `MONK_ENV=test`, since anywhere else it
  would empty a real queue.

12. ~~The same contract, backed by one queue Ractor (the `StateRactor`
    pattern). Passes the shared adapter suite.~~ Built, then dropped (see
    above).
13. `Monk::Jobs.drain!`: runs ready jobs synchronously in the calling
    Ractor until the queue is empty, and fails loudly if a job raises. It
    is the default in `MONK_ENV=test`, so an app's tests can assert on the
    effects of enqueued jobs without starting a worker process. (Built on
    the Postgres queue, running each job in a Ractor, see above.)

## Phase 6 — Ractor runtime (Seams C and D) — DONE 2026-09-27

`lib/monk/jobs/runtime.rb` (the supervisor, `require "monk/jobs/runtime"`),
`lib/monk/jobs/worker.rb`, and `register_process`, `heartbeat`, `prune`,
`release`, `deregister`, `reset_connection` in the Postgres adapter.
Tests:

- `test/jobs_pg_processes_test.rb` (7): the process operations.
- `test/jobs_runtime_test.rb` (14): the runtime in one process, on a
  thread, with real worker Ractors.
- `test/jobs_process_test.rb` (4): real child processes, via
  `test/support/jobs_process.rb`, stopped with `TERM` and `kill -9`.
- The `timeout` job setting's tests are in `test/jobs_job_test.rb`.

All were stable over repeated runs.

`Monk::Jobs::Runtime.new(queues:, workers:, poll_interval:,
tick_interval:, heartbeat_interval:, process_timeout:,
shutdown_timeout:).run(trap_signals: true)`. Defaults: `["default"]`, 5
workers, 1 s poll, 1 s tick, 15 s heartbeat, 120 s process timeout, 25 s
shutdown timeout. `#stop` does what `TERM`/`INT` do, for tests.

**Differences from the steps below, and what building it found:**

- **The heartbeat is an upsert.** A process that stalled long enough for
  another to prune it gets its row back under the same id. The jobs
  pruning released stay with whoever claimed them since, and this
  process's late `finish`/`fail` calls on them find nothing held.
- **Pruning also releases orphans:** running jobs with no process row at
  all (a crashed `drain!`), after the same `process_timeout` grace
  period.
- **Per-job timeout is a job setting,** `timeout 30`. Its default is
  `nil`, meaning no limit. A timed-out run is failed and retried like any
  other failure, and the worker then cancels and resets its connection
  (`adapter.reset_connection`) before claiming again. Open point: only the
  queue database's connection is reset. A job that timed out mid-query on
  a different registered database leaves that connection busy until the
  query ends.
- **Every exception fails the job**, not only StandardErrors (the worker
  uses `rescue Exception`). Otherwise a job could be left `running` inside
  a live process, which pruning never touches.
  `UnknownJobError` and `NotImplementedError` never retry. After failing
  the job, a non-StandardError is re-raised, so the worker Ractor ends and
  the supervisor respawns it on its next tick. A worker that dies straight
  away, for example because the database is down, is therefore restarted
  at most once per tick.
- **The Postgres-restart risk is covered, which took two additions:**
  - Each worker tells the supervisor which job it holds (a port message
    after claiming, another after finishing or failing). When a worker
    dies, the supervisor releases that job with `release(id,
    process_id)`. This covers a job that ran but whose `finish` never
    reached the database; without it, that job would stay `running` until
    the whole process restarted. Tested with a job that kills its own
    connection at the end of its first run.
  - A database error in the supervisor's tick (stage, heartbeat, prune,
    release) is logged, its connection is reset, and the next tick tries
    again. It no longer ends `run`. `deregister` failing on the way out is
    logged; that process's jobs are then released by another process's
    pruning. Tested by killing every database connection of a real child
    process, after which new jobs still run.
- **`monk/jobs` now requires the whole framework** (`require_relative
  "../monk"`, as `monk/live` does). `Monk.freeze!` needs
  `Persistence::Model`, which only `require "monk"` loads. The in-process
  tests hid this, because `test_helper` loads `monk`. The child-process
  test found it.
- **`monk_processes` stays one row per OS process.** Workers are
  identified to the supervisor by index, not by database rows.
- Open point: a job released by a graceful stop's `deregister` or by
  pruning keeps its attempt counted, as Decision 4 says. Jobs longer than
  `shutdown_timeout` therefore spend an attempt on every deploy.

14. `Monk::Jobs::Runtime.new(queues:, workers:, poll_interval:,
    tick_interval:).run`: the main Ractor registers a `monk_processes`
    row, spawns the workers (one monitor port each, Phase 0.4), then
    loops on its tick: stage due jobs, heartbeat, prune.
15. Worker loop: claim → look up the class → `perform(*args)` →
    `finish`, or `fail` with backoff. Anything a job raises is rescued
    inside the worker, `NotImplementedError` included (Phase 5), so one bad job never kills the Ractor. A Ractor
    that dies anyway is respawned by the supervisor (Phase 0.4).
16. Pruning: processes whose heartbeat is older than the threshold have
    their `running` jobs set back to `available` (Decision 4) and their
    row deleted.
17. Graceful stop on `TERM`/`INT`: stop claiming, wait up to
    `shutdown_timeout` for jobs in flight, set whatever is still
    `running` back to `available`, delete the process row.
18. Per-job timeout: `Timeout.timeout` around `perform`, then `cancel` or
    `reset` of the worker's connection before its next claim (Phase 0.3).
19. Seam D: a real child process. Enqueued jobs run. `kill -9` of the
    child, followed by a second process pruning it, re-runs the orphaned
    job exactly once. `TERM` finishes the job in flight and leaves nothing
    claimed.

## Phase 7 — Optional `NOTIFY` wake-up — SKIPPED 2026-09-27

Not built in v1; moved to "Explicitly out of scope" below. The plan was:

20. `Monk::Jobs.configure(notify: true)`: `enqueue` adds `pg_notify`
    in the same transaction, and a listener Ractor in the job process
    (the `PgFanout` subscriber loop) wakes idle workers early. Polling
    keeps running regardless. Documented as for low-to-moderate write
    volume only, with ADR 0013's commit-lock caveat.

**Why it was skipped:**

- **The gain is small and narrow.** It only shortens the wait for jobs
  enqueued to run immediately, and only while workers are idle. With the
  default `poll_interval` of 1 s, that wait is about 0.5 s on average and
  1 s at worst. Busy workers claim the next job at once anyway, and
  scheduled jobs and retries are promoted by the supervisor's tick, not
  by a notification.
- **Polling faster gets most of it for free.** An idle poll is one query
  against a small partial index. At `poll_interval: 0.2` with 5 workers,
  that's about 25 small queries a second per job process, bringing the
  average wait to about 0.1 s.
- **The cost grows with load, while the benefit matters most at low
  load.** A transaction that issued `NOTIFY` takes a database-wide lock
  at commit (ADR 0013), so every transaction that enqueues a job would
  commit one at a time. That falls on the app's own transactions exactly
  when the app is busy. `LISTEN` also needs a session connection per job
  process, so it doesn't work behind PgBouncer in transaction mode.
- **It adds real moving parts:** a listener Ractor for the supervisor to
  respawn, a reconnect path, a `:wake` control message for workers, and
  tests for missed notifications.

To revisit only if Phase 10 (login-link email latency) shows that
tuning `poll_interval` isn't enough.

## Phase 8 — Scaffolding: `monk new --jobs` (Seam E) — DONE 2026-09-27

Templates under `lib/monk/templates/jobs/` (`config/jobs.rb`,
`jobs/hello_job.rb`, `bin/jobs`, plus Phase 1's migration),
`Monk::Scaffold`'s `jobs:` option, `--jobs` in `exe/monk`, and the
scaffolding and deploying guides. Tests: `test/scaffold_jobs_test.rb`
(12), including loading the generated config and running `HelloJob`
through `drain!` against the test database, and running the generated
`bin/jobs` as a real process (with `BUNDLE_GEMFILE` pointed at Monk's own
bundle), stopped with `TERM`. Two more tests are in
`test/exe_monk_test.rb`.

**Differences from the steps below, and what building it found:**

- **The demo route is `POST /jobs/hello`,** added after the
  `/api/hello` route. Both the base and the `--live` `config.ru` end their
  routes with that line, so one edit covers both.
  `config/jobs` is required after `config/persistence` (or
  `config/auth`) and `config/mail`.
- **`JOBS_WORKERS` and `JOBS_QUEUES` go in `.env` and `.env.example`
  only.** Tests run jobs with `drain!`, never with a job process.
- **`bin/jobs` loads `config/mail.rb` and `config/auth.rb` when present**
  (like `bin/websocket_server` does with `config/auth.rb`), so jobs can
  send mail. It sets `Monk::Views.root` to the app's `views/` itself,
  since there's no `App` class there to do it, and a job may render a
  mail template.
- **SETUP.md's test section** adds `config/jobs` to the test helper and a
  sample `test/jobs_test.rb` using `drain!` and `clear!`. This resolves
  the open point about how a generated app's tests are wired for jobs.
- **Adding jobs to an existing app** is covered in `scaffolding.md`'s
  retrofit section, next to Postgres, Auth and Redis, rather than in the
  jobs guide.
- **Deploying:** `bin/jobs` is one more command on the same image, with
  no port. Docker and Compose send `KILL` 10 s after `TERM` by default,
  shorter than `bin/jobs`'s 25 s `shutdown_timeout`, so the Compose
  example sets `stop_grace_period: 30s`. Without it, a job killed mid-run
  waits for another process's pruning (2 minutes) to be picked up again.
- **Found: a Phase 6 test killed other tests' connections.**
  `test_a_job_process_survives_losing_every_database_connection`
  terminated every backend in the test database except its own. That
  included connections other test files keep for the whole run, such as
  the Live tests' `PgFanout` publisher, so some random orders failed
  `LivePgTest`. The child job process's connections now carry an
  `application_name`, and the test kills only those.
- **Found, not fixed (outside this plan):** SETUP.md's sample Postgres
  test, generated for `--postgres` without `--auth` and unrelated to
  jobs, asserts `assert_equal "1", conn.exec("SELECT 1").getvalue(0, 0)`.
  Monk's connections decode integers, so the value is `1`, and a
  generated app's copy of that test fails.

21. `--jobs` implies `--postgres` (`@postgres = postgres || auth ||
    jobs`) and nothing else. It works with or without
    `--auth`/`--mail`/`--live`/`--redis`.
22. Files:
    - `config/jobs.rb`: `Monk::Jobs.configure(db_name: :primary, …)`
      (Decision 13), with a comment pointing to the guide's
      separate-database section, plus requires for `jobs/*.rb`.
    - `jobs/hello_job.rb`: a demo job logging through `Monk::Log`.
    - `bin/jobs`: loads settings, persistence, the app's jobs and the
      views, calls `Monk.freeze!`, then `Monk::Jobs::Runtime.new(…).run`.
    - `db/migrate/00000000000002_create_jobs_tables.{up,down}.sql`.
      Version 2 so it sorts after auth's `…01` when both are present;
      it's harmless without auth.
23. Wiring: `config.ru` requires `config/jobs`, so routes can enqueue.
    A demo route (e.g. `POST /hello/job`) enqueues `HelloJob` so the
    scaffold shows the round trip end to end.
24. `.env`/`.env.test`: `JOBS_WORKERS`, `JOBS_QUEUES`. `SETUP.md` gains a
    "Background jobs" section (run `bin/migrate`, then `bin/jobs` beside
    `bin/server`). `exe/monk` usage and help text mention `--jobs`.
25. Dockerfile and `docs/guides/deploying.md`: the job process is a
    second command on the same image, like `bin/websocket_server`.
26. Retrofitting an existing app: the guide lists the files to copy and
    the migration to add. Whether Monk should also ship a `monk jobs:install`-style
    command is out of scope (see below).

## Phase 9 — Docs

27. `docs/guides/jobs.md`: defining a job, enqueueing it (with and
    without `conn:`), idempotency first, retries and failed jobs,
    scheduling, running `bin/jobs`, sizing workers, tuning
    `poll_interval` (pickup latency) and `tick_interval` (how late a
    scheduled job may start), testing jobs
    (`drain!`, `clear!`, `in_ractor: false`). A
    "Keeping the queue healthy" section: long transactions as the main
    risk, `idle_in_transaction_session_timeout`, the autovacuum settings,
    and when and how to move the queue to its own database (Decision 13,
    Phase 0.1b).
28. README features table, `CONTEXT.md` vocabulary (**Job**, **Queue**,
    **Job state** (available / scheduled / running / failed), **Payload**,
    **Stager**, **Job process**), CHANGELOG.

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
  holds a usable one. Putting the link in `monk_job_payloads.args` undoes that
  for the job's lifetime, and for longer in failed jobs. Options: accept
  it with delete-on-finish and a short `max_attempts`; encrypt args with
  `AUTH_SECRET`; or keep magic links synchronous and make everything else
  asynchronous.
- **Latency for a user who is waiting.** A login link waits for the poll
  interval plus the queue ahead of it. Candidates: a dedicated `mailers`
  queue with its own job process and a short `poll_interval`, or a high
  priority. Phase 7's `NOTIFY` wake-up, skipped, is the fallback if
  neither is enough.
- **Which failures to retry.** `DeliveryError` (the relay is unreachable
  or rejected the send) is worth retrying. `InvalidMessageError` never
  is, and should go straight to failed.
- **Scaffolding.** What `monk new --auth --jobs` (and `--mail --jobs`)
  generate. `config/auth.rb` probably gets a jobs-aware variant.
- **Records to update**: ADR 0012's "Monk has no job queue" paragraph,
  and `docs/guides/mail.md` / `auth.md`.

## Explicitly out of scope for this plan

- Recurring (cron) jobs, concurrency limits, pausing queues, batches.
  Each can be added later as its own table or column, without changing
  the claim query.
- Keeping finished jobs, and any dashboard or web UI.
- A Redis adapter.
- Threads inside a worker Ractor (more than one job at a time per Ractor
  for IO-bound work). v1 runs one job per worker Ractor; revisit if mail
  delivery (Phase 10) shows the need.
- A `monk jobs:install` retrofit command.
- Running job workers inside the web server's process.
- Waking idle workers with `LISTEN`/`NOTIFY` (Phase 7, skipped): lower
  `poll_interval` instead. Revisit only if Phase 10 shows a real need.

## Risks worth watching

- **Gems that job code calls.** Job code runs in a worker Ractor, so
  every gem it touches has to survive there: module ivars, class
  variables and `define_method` blocks all fail (`docs/design/ractor.md`,
  ADR 0012's `mail` gem finding). The guide has to say this plainly.
  `drain!` runs jobs in a Ractor by default (Phase 5), so an app's tests
  catch it, unless they opt out with `in_ractor: false`.
- **A timed-out job leaves its query running on the server** (Phase
  0.3): if the worker doesn't cancel or reset its connection, the next
  claim waits for the abandoned query to finish.
- **Long transactions on the same database** slow the queue in any
  schema (Phase 0.1). This is the main operational risk to document.
- **At-least-once delivery surprising apps** that send non-idempotent
  side effects (charges, emails). This is the main reason Phase 10's mail
  design needs care.
- **Postgres restart or failover** while `bin/jobs` runs. Covered in
  Phase 6: workers that lose their connection are respawned, the job a
  dead worker held is released, and the supervisor reconnects on its
  next tick. Tested by killing connections, not by a real server restart
  or failover.
