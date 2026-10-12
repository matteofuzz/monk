# Recurring jobs (`Monk::Jobs.recurring`) — implementation plan

Branch: `main_dev/scheduled_job`, merged into `main_dev/dev_0_22_0` by its
own PR. Designed 2026-10-06; updated 2026-10-12 for scaffolding by module
(`monk add jobs`, ADR 0017). Phases 0–4 done.
Builds on [`history/plan-jobs.md`](history/plan-jobs.md), which left recurring (cron)
jobs out of v1 and noted they could be added "as its own table or column,
without changing the claim query". This plan does exactly that: the claim
path, the stager and the worker loop don't change.

Same approach as the other plans: small red → green slices, one failing
test per seam, against a real test Postgres. Ruby 4.0.6.

## The problem

An app wants a job to run on a schedule: purge expired sessions every
night, send a digest every Monday, refresh a cache every five minutes.
Today the only ways are an external cron calling a script, or a job that
enqueues its own next run. Both are poor fits (see below). Monk should
let an app declare the schedule in code and have `bin/jobs` enqueue each
run exactly once, however many job processes are running.

## Constraints from what exists

- **Delayed jobs already work.** `wait:`/`at:` enqueue a job as
  `scheduled`, and the supervisor's 1 s tick stages it once it's due. A
  recurring job only needs something to call `enqueue` at the right
  moment. Nothing about claiming or running changes.
- **Every `bin/jobs` process runs the same tick** and they share no
  memory. With more than one process, something must stop each
  occurrence from being enqueued twice.
- **Finished jobs are deleted**, so `monk_jobs` can't remember that an
  occurrence already ran.
- **No new gem dependency** (ADR 0013): no `fugit`, no `tzinfo`.
- **No advisory locks** (ADR 0013): they hold a connection open and
  break behind PgBouncer in transaction mode.
- **Mistakes fail at boot** (ADR 0003), and anything a Ractor reads is
  frozen by `Monk.freeze!` through `Monk.freeze_hooks`. `Monk::Jobs` is
  already one of those hooks.
- **`CONTEXT.md` already reserves "Scheduler"** for recurring jobs (the
  "Stager" entry says to avoid the word for anything else).

## Options considered

Who triggers the enqueue:

| Option | Verdict |
|---|---|
| **A. External cron** (crontab, platform cron, k8s CronJob) running a script that enqueues | Rejected. Different on every platform, the schedule lives outside the app, it boots the app on every run, there's nothing like it in dev, and it can't be tested. Mentioned in the guide as a workaround. |
| **B. Jobs that re-enqueue themselves** | Rejected. Someone has to enqueue the first run (and deploys add duplicates). The chain breaks for good when a job fails or is discarded, and start times drift. |
| **C. Scheduler on the `bin/jobs` supervisor tick, deduplicated in Postgres** | **Chosen.** No new process. Reuses the existing 1 s tick. Any live process can fire a run, so it survives a process dying. The database clock decides when a run is due. |
| **D. A separate `bin/scheduler` process** | Rejected. One more process to deploy. If it dies nothing fires, unless it deduplicates too, and then it's C in its own process. |
| **E. One leader process schedules from memory**, chosen by an advisory lock | Rejected. Advisory locks are ruled out. There's a gap while a new leader takes over, and missed runs need saved state anyway. |

How C deduplicates:

| Variant | Verdict |
|---|---|
| **C1. One row per occurrence** (`key, occurrence` primary key; insert, skip on conflict, then enqueue), as Solid Queue does | Rejected. The table grows forever and needs pruning, keeping a history nobody asked for. |
| **C2. One checkpoint row per task**, moved forward only if it's older than this occurrence, in the same statement as the enqueue | **Chosen.** Fixed size. It also tells us what was missed during downtime. It fits ADR 0013's style of one narrow statement per step. |
| **C3. A unique key on `monk_jobs`** (`cron_key, cron_at`), as GoodJob does | Rejected. It adds a column to the hot narrow table, and it's wrong: finished jobs are deleted, so the key stops protecting the moment the job finishes, and a process that computes the same occurrence late enqueues it again. |

## Language

New terms for `CONTEXT.md` (Phase 7):

- **Recurring task**: one declared schedule. It has a key, a job class, a
  cron expression and the args to enqueue with. One job class can have
  several, with different args.
- **Occurrence**: a minute matched by a task's cron expression, in UTC.
- **Checkpoint**: the latest occurrence a task has been handled for
  (enqueued, skipped, or set when the task was first seen). Stored in
  `monk_recurring_tasks`.
- **Scheduler**: the supervisor's per-tick step that handles each task's
  most recent occurrence. It sits next to the stager and is separate
  from it.

## Decisions

1. **Scheduler on the supervisor tick (option C2).** `Runtime#tick` runs
   the scheduler next to `stage_due`, under the same `rescue`: a
   database error is logged and retried on the next tick. Every job
   process runs it for every task, whatever queues that process serves.
   `enqueue` doesn't care which process calls it.

2. **Declared in `config/recurring.rb`, keyed explicitly.** For example:

   ```ruby
   Monk::Jobs.recurring "purge_sessions", PurgeExpiredSessions, cron: "0 3 * * *"
   Monk::Jobs.recurring "weekly_digest", SendDigest, cron: "0 9 * * 1", args: ["weekly"], skip_if_pending: true
   ```

   The key is a non-empty String and must be unique. It's the task's
   identity in the database, so renaming the job class doesn't lose the
   checkpoint. Checked at declaration, so a mistake fails at boot:
   - the job class is a named `Monk::Job` subclass (`check_enqueueable!`);
   - `args:` passes `Args.check!`;
   - the cron expression parses and matches at least one minute (an
     expression like `0 0 30 2 *` never does);
   - no other task has the same key.

   **Load order.** The declarations need the job classes, but
   `config/load.rb` requires the module configs (`config/jobs.rb`
   included) *before* `app/jobs/`. So they go in their own file,
   `config/recurring.rb`, which the base template's `config/load.rb`
   requires *after* the app's code, if it exists. The jobs generator
   writes it. Only new apps get the new `load.rb`; an existing app
   follows the 0.22 upgrade guide (Phase 7).

   Declarations are stored in a list, and `freeze_registry!` makes that
   list shareable. Declaring after the registry is frozen raises
   `RegistryFrozenError`, since the scheduler would never see the task.
   `args:` are deep-copied, so changing the caller's Array afterwards
   doesn't change the task. Queue, priority and `max_attempts` come from the job
   class, as with any `enqueue`.

3. **Cron syntax, UTC only.** Our own small parser, `Monk::Jobs::Cron`,
   with no dependency:
   - Five fields: minute, hour, day of month, month, day of week.
   - In each field: `*`, numbers, lists (`,`), ranges (`-`) and steps
     (`/`). Day of week runs 0–7, with both 0 and 7 meaning Sunday.
   - Shortcuts: `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`.
   - When both day of month and day of week are restricted, a day
     matching either one counts, as in Vixie cron. Also as in Vixie, a
     field starting with `*` doesn't count as restricted, steps included:
     `0 0 */2 * 1` is Mondays that fall on an odd day.
   - A step goes on `*` or a range: `5/10` is rejected rather than read
     as `5-59/10`.
   - No seconds, no names (`jan`, `mon`), no time zones. Every time is
     UTC, and the guide says so plainly.
   - A parsed expression is a frozen `Data` of frozen integer sets, so it
     can be shared across Ractors.
   - Two pure methods, both returning a UTC `Time` on a whole minute:
     `previous(t)` is the latest occurrence at or before `t`, and
     `next_after(t)` is the first occurrence after `t`. Both step
     field by field (month, then day, then hour, then minute) rather than
     minute by minute, so a yearly expression takes a handful of steps.

4. **One checkpoint row per task**, in a new table:

   `monk_recurring_tasks`:
   - `key TEXT PRIMARY KEY`
   - `cron TEXT NOT NULL`: the expression the checkpoint was set under
     (decision 8)
   - `last_occurrence_at TIMESTAMPTZ NOT NULL`: the checkpoint
   - `last_job_id BIGINT`: the job enqueued for the checkpoint, used by
     decision 7
   - `updated_at TIMESTAMPTZ NOT NULL DEFAULT now()`

   There's deliberately no foreign key from `last_job_id` to `monk_jobs`.
   `ON DELETE SET NULL` would add a trigger-driven write to every job's
   finish, the busiest path in the queue. A dangling id just means "that
   job is done", which is exactly what decision 7 asks.

5. **What the scheduler does on each tick, for each task:**
   1. Compute `occurrence = cron.previous(Time.now.utc)`.
   2. If it equals the occurrence this process last handled for the task
      (kept in a supervisor-local Hash), do nothing. This means the
      database is touched once per occurrence per process, not once per
      tick.
   3. Otherwise call the adapter's `fire_recurring` with the key, the
      cron expression, the occurrence, the enqueue parameters and
      `skip_if_pending`. It returns one of:

      | Result | Meaning |
      |---|---|
      | `:initialized` | The task had no row. The checkpoint was set to this occurrence and nothing was enqueued (decision 6). |
      | `:enqueued` | The checkpoint moved forward and a job was enqueued. |
      | `:skipped_pending` | The checkpoint moved forward. The previous job is still pending, so nothing was enqueued (decision 7). |
      | `:already_handled` | Another process got there first: the checkpoint is already at or past this occurrence. |
      | `:not_due` | By the database clock, the occurrence hasn't arrived yet. |
      | `:reinitialized` | The cron expression changed. The checkpoint was reset without firing (decision 8). |

   4. Remember the occurrence as handled for every result except
      `:not_due`, which is retried on the next tick.

   `fire_recurring` is one statement, like `ENQUEUE_SQL`. The checkpoint
   update is a compare-and-set: it applies only if `last_occurrence_at`
   is older than the occurrence **and** the occurrence is not later than
   `now()`. If the update applies, the same statement inserts the job and
   its payload (`run_at = now()`, so `available` at once) and records the
   job's id. Two processes racing on the same occurrence both run the
   update; row locking lets exactly one of them advance the checkpoint,
   and the other gets `:already_handled`. Gating on `now()` means a
   process whose clock runs fast can't fire early; the most it can do is
   ask a little sooner.

   The statement records `last_job_id` without updating the same row
   twice: it draws the job's id from the identity sequence first and
   inserts with `OVERRIDING SYSTEM VALUE`, as `HEARTBEAT_SQL` already
   does. Phase 0 confirmed it; the statement is in "Phase 0 results".

6. **Missed runs fire once, and new tasks don't fire on deploy.** The
   scheduler only ever asks about the most recent occurrence, so after
   downtime a task whose checkpoint is several occurrences behind fires
   once, for the latest occurrence. The ones in between are skipped and
   a line is logged ("purge_sessions: caught up from <checkpoint>,
   skipped N occurrences"; the old checkpoint comes back from the
   statement). A task with no row is inserted with the checkpoint set to
   the current occurrence and nothing enqueued. Otherwise every deploy
   that adds a daily task would run it at once. Two processes seeing a
   new task at the same time is handled by `INSERT ... ON CONFLICT DO
   NOTHING`.

7. **`skip_if_pending:` is opt-in (default `false`).** Overlap is allowed
   by default: a run starts even if the previous one is still waiting or
   running, so jobs must be idempotent (they already must be, given
   at-least-once delivery). With `skip_if_pending: true`, the statement
   checks whether `last_job_id` still exists in `monk_jobs` with a state
   other than `failed`. Because finished jobs are deleted, "still exists"
   means "not done". If it's pending, the checkpoint still moves forward
   (the occurrence is used up, not delayed) and the result is
   `:skipped_pending`, logged at info. A failed previous run doesn't
   block the next one; otherwise one failure would stop the task for
   good.

8. **A changed cron expression resets the checkpoint without firing.**
   Moving `0 3 * * *` to `0 4 * * *` with a deploy at 10:00 would
   otherwise see today's 04:00 as a missed occurrence and fire at once.
   When the row's `cron` differs from the declared one, the statement
   sets `cron` and the checkpoint to the current occurrence and enqueues
   nothing (`:reinitialized`). A known limitation: during a rolling
   deploy, old and new processes keep resetting the row back and forth,
   so the task can miss an occurrence that falls inside the overlap. The
   guide says so.
   Changing `args:` or `skip_if_pending:` doesn't touch the checkpoint.

9. **The table is checked when `bin/jobs` starts.** If any tasks are
   declared and `monk_recurring_tasks` doesn't exist (an existing app
   that didn't add the migration), `Runtime#run` raises before starting
   workers. The supervisor doesn't log a failure every second instead.

   An app that already has jobs gets nothing from `monk add jobs` (the
   module counts as installed, ADR 0017). The error names the migration
   and `monk help jobs --file db/migrate/x_create_recurring_tables.up.sql`,
   which prints Monk's version (it matches a migration by name, whatever
   its timestamp), and points at the 0.22 upgrade guide (Phase 7), which
   has the full steps. No upgrade command. The startup log line also
   lists how many recurring tasks there are.

10. **Rows for removed tasks are left alone.** They're tiny and nothing
    reads them. A removed key that is later declared again starts from
    its old checkpoint, so it fires its latest occurrence once. That's
    acceptable, and documented. Pruning stays an open question.

11. **Testing.** Three pieces:
    - **`Monk::Jobs.run_scheduler!(at: Time.now)`**: runs one scheduler
      pass as if the clock read `at`. The database gate compares against
      `at` instead of `now()`, so the call is test-only, and like
      `clear!` it refuses to run unless `MONK_ENV=test`. A test calls it
      once to initialize the task, then again at a later occurrence, then
      `drain!`s.
    - **`drain!` never fires schedules**, so existing tests don't change.
    - **`clear!` also empties `monk_recurring_tasks`**, `reset!` forgets
      the declared tasks, and the pure `Cron#previous`/`#next_after`
      let an app check "this runs Mondays at 09:00" with no database at
      all.

## Phases

0. **Spike (throwaway, results recorded here).**
   - **The single `fire_recurring` statement.** Write it with all of
     decision 5's outcomes and check each against a real Postgres 16.
   - **Racing processes.** Run 8 Ractors firing the same occurrence 1,000
     times: exactly one `:enqueued` per occurrence. Measure what one
     occurrence costs with P processes.
   - **Ractors.** Confirm a parsed `Cron` `Data` is `Ractor.shareable?`
     once frozen.
   **Results (2026-10-12, Postgres 16.15, Ruby 4.0.6). All passed.**
   - **One statement covers all six outcomes** (below). Checked: each
     outcome; catch-up fires once and returns the old checkpoint;
     `:reinitialized` clears `last_job_id` and enqueues nothing;
     `skip_if_pending` skips while the previous job is available,
     running or scheduled for a retry, and enqueues when it failed or
     finished; `skip_if_pending: false` ignores a pending job; the
     optional clock (`$10`, for `run_scheduler!(at:)`) makes a future
     occurrence due, and without it the database clock decides.
   - **Racing processes.** 8 connections, each on its own thread (the
     database race is the same as with Ractors; the per-Ractor
     connection path is exercised again in Phase 4), firing each of 1,000
     occurrences together: exactly 1,000 `:enqueued`, 7,000
     `:already_handled`, 1,000 jobs and 1,000 payloads. About 4.3 ms per
     occurrence for all 8 (0.5 ms a call), against a local database.
     Two more races: with `skip_if_pending` and the previous job
     finished between occurrences, every occurrence enqueued once and
     none was skipped; with half the processes a minute behind, no
     occurrence was enqueued twice and the checkpoint ended at the
     latest one.
   - **Ractors.** A frozen `Data` of frozen `Set`s (and of frozen
     `Array`s) is `Ractor.shareable?` and readable inside a Ractor.
   - **How it works.** `seq` draws the job id up front, so the one
     `UPDATE` both moves the checkpoint and records the job. That burns
     an id on every call that doesn't enqueue: once per occurrence per
     process, harmless on a `BIGINT`. `ins`, `reinit` and `advance`
     touch the row in mutually exclusive cases. The pending check is a
     correlated subquery on `t.last_job_id` inside `advance`, so when an
     `UPDATE` waits on a racing one, READ COMMITTED's recheck evaluates
     it again on the row's latest version. The payload's foreign key is
     checked at the end of the statement, as in `ENQUEUE_SQL`.
   - **Known imprecision.** `previous_checkpoint` comes from the
     statement's snapshot, so in a race it can be older than the row the
     winner actually advanced. It only feeds decision 6's "skipped N
     occurrences" log line, so that line can over-count during a race.
     Accepted.

   Parameters: `$1` key, `$2` cron, `$3` occurrence, `$4`
   skip_if_pending, `$5` queue, `$6` priority, `$7` max_attempts, `$8`
   job class, `$9` args (JSON), `$10` clock (`NULL` means `now()`; set
   only by `run_scheduler!`).

   ```sql
       WITH gate AS (
         SELECT $3::timestamptz <= COALESCE($10::timestamptz, now()) AS due
       ), prev AS (
         SELECT last_occurrence_at FROM monk_recurring_tasks WHERE key = $1
       ), seq AS (
         SELECT nextval(pg_get_serial_sequence('monk_jobs', 'id')) AS id
       ), ins AS (
         INSERT INTO monk_recurring_tasks (key, cron, last_occurrence_at)
         SELECT $1, $2, $3 FROM gate WHERE due
         ON CONFLICT (key) DO NOTHING
         RETURNING key
       ), reinit AS (
         UPDATE monk_recurring_tasks t
         SET cron = $2, last_occurrence_at = $3, last_job_id = NULL, updated_at = now()
         FROM gate
         WHERE gate.due AND t.key = $1 AND t.cron <> $2
         RETURNING t.key
       ), advance AS (
         UPDATE monk_recurring_tasks t
         SET last_occurrence_at = $3, updated_at = now(),
           last_job_id = CASE
             WHEN $4::boolean AND EXISTS (
               SELECT 1 FROM monk_jobs j WHERE j.id = t.last_job_id AND j.state <> 'failed'
             ) THEN t.last_job_id
             ELSE seq.id
           END
         FROM gate, seq
         WHERE gate.due AND t.key = $1 AND t.cron = $2 AND t.last_occurrence_at < $3
         RETURNING t.last_job_id IS DISTINCT FROM seq.id AS skipped, seq.id AS job_id
       ), job AS (
         INSERT INTO monk_jobs (id, queue, priority, max_attempts, run_at, state) OVERRIDING SYSTEM VALUE
         SELECT job_id, $5::text, $6::smallint, $7::smallint, now(), 'available' FROM advance WHERE NOT skipped
         RETURNING id
       ), payload AS (
         INSERT INTO monk_job_payloads (job_id, job_class, args)
         SELECT id, $8::text, $9::jsonb FROM job
       )
       SELECT CASE
           WHEN NOT (SELECT due FROM gate) THEN 'not_due'
           WHEN EXISTS (SELECT 1 FROM ins) THEN 'initialized'
           WHEN EXISTS (SELECT 1 FROM reinit) THEN 'reinitialized'
           WHEN EXISTS (SELECT 1 FROM advance WHERE skipped) THEN 'skipped_pending'
           WHEN EXISTS (SELECT 1 FROM advance) THEN 'enqueued'
           ELSE 'already_handled'
         END AS result,
         (SELECT id FROM job) AS job_id,
         (SELECT last_occurrence_at FROM prev) AS previous_checkpoint
   ```

1. **`Monk::Jobs::Cron` (pure, no database).**
   - Parsing every supported form; clear errors for out-of-range values,
     wrong field counts and unknown shortcuts.
   - The rule that a day matching either restricted day field counts;
     both 0 and 7 meaning Sunday.
   - `previous`/`next_after`:
     - at an exact occurrence and between occurrences;
     - across month, year and leap-day boundaries;
     - `0 0 29 2 *` (found within 8 years);
     - `0 0 30 2 *` (rejected as never matching).
   - Non-UTC input times are converted to UTC.
2. **Declaration and registry.**
   - `Monk::Jobs.recurring` with every check in decision 2.
   - Frozen by `freeze_registry!` and readable from a Ractor afterwards.
   - `reset!` clears declarations.
   - A `Monk::Jobs.recurring_tasks` reader, for the runtime and for tests.
3. **Schema and adapter.**
   - Migration `lib/monk/templates/jobs/db/migrate/00000000000003_create_recurring_tables.{up,down}.sql`,
     and the matching table in the test schema. The `00000000000003`
     prefix only orders the templates; the generator stamps the copy.
   - `Adapters::Pg#fire_recurring` with one test per outcome of decision
     5, including `skip_if_pending` with a pending, a running, a failed
     and a finished previous job.
   - The checkpoint comes back from the statement so decision 6 can log
     it.
   - `clear!` empties the new table.
   **Done (2026-10-12).** `Adapters::Pg#fire_recurring` runs the Phase 0
   statement and returns a `Monk::Jobs::Firing` (`result`, `job_id`,
   `previous_checkpoint` as a UTC `Time` or `nil`); the occurrence and
   clock go in as ISO 8601, and the checkpoint comes back as epoch
   seconds, so neither depends on the connection's type map. Tests:
   `test/jobs_pg_recurring_test.rb` (18), plus the table's shape in
   `test/jobs_schema_test.rb`.
   Pulled forward from Phase 6: the jobs generator's
   `migration "create_recurring_tables"` line (and its test). `clear!`
   now deletes from `monk_recurring_tasks`, so a scaffolded app's own
   tests fail without the table. The same goes for an existing app
   until it adds the migration; the upgrade guide (Phase 7) says so.
4. **Runtime integration.**
   - The scheduler step in `Runtime#tick`, with the per-process "last
     handled" Hash.
   - The table check and log line from decision 9.
   - A test that two `Runtime`s running against the same database
     enqueue each occurrence once.
   - A test that a database error during the scheduler step is logged and
     retried on the next tick.
   **Done (2026-10-12).** The per-tick step is its own class,
   `Monk::Jobs::Scheduler` (`lib/monk/jobs/scheduler.rb`): the adapter,
   the tasks and the "last handled" Hash, with `run(now, clock: nil)`,
   which Phase 5's `run_scheduler!(at:)` reuses. Differences from the
   plan above:
   - **Its own `rescue`, after the heartbeat.** Under the stager's
     `rescue`, an error only the scheduler hits would skip the heartbeat
     on every tick, and other processes would prune this one as dead.
     `Runtime#tick` now runs `housekeeping` (release, stage, beat) and then
     `schedule`, each logging and reconnecting on its own.
   - **The "two processes" test is on `Scheduler`**
     (`test/jobs_scheduler_test.rb`): two instances against one database,
     with fixed times, instead of two `Runtime`s on real time, which would
     wait for minute boundaries and share one connection in a test
     process. Phase 0 already raced 8 real connections.
     `test/jobs_runtime_test.rb` covers the wiring: an overdue task is
     enqueued and run, the startup check, no tasks needing no table, and a
     scheduler error (a view it can't write to) logged and retried while
     heartbeats go on.
   - **Log lines**, prefixed `Monk::Jobs recurring <key>:`: info for a new
     task (with its first run), a changed cron, each enqueue and each
     `:skipped_pending`; warn for a catch-up ("caught up from …, skipped N
     occurrences", counting stops at 10,000).
   - Decision 9's error is `Monk::Jobs::MissingRecurringTableError`,
     checked through `Adapters::Pg#recurring_table?` before the process
     registers. The startup line reads "…, N recurring tasks (pid …)".
5. **Testing helper.** `run_scheduler!(at:)` with its `MONK_ENV=test`
   guard, plus an end-to-end test: declare, initialize, advance, `drain!`.
6. **Scaffolding (`monk add jobs`, `lib/monk/generators/jobs.rb`).**
   Generators only create files and append lines (ADR 0017), so this is
   template content and DSL lines; no generator code changes.
   - **Base template, `config/load.rb`:** after the `app/` roles are
     loaded, `require` `config/recurring.rb` if it exists, with a comment
     saying why it comes last (decision 2). `test/generators/base_test.rb`
     covers that it's loaded after `app/jobs/`.
   - **Jobs generator:**
     - `copy "config/recurring.rb", role: :wiring`: a commented example
       tagged `monk:example jobs-recurring`,
       `Monk::Jobs.recurring "hello_hourly", HelloJob, cron: "@hourly", args: ["cron"]`.
       Commented, because a demo task firing in every developer's
       `bin/jobs` is noise. Plus
       `example "jobs-recurring", todo: "uncomment to run the demo job every hour"`.
     - ~~`migration "create_recurring_tables"` after `create_jobs_tables`~~:
       done in Phase 3. A new app gets both, stamped one second apart in
       that order (`Run#migration_entries`).
   - `jobs/setup.md`: a "Recurring jobs" step (declare in
     `config/recurring.rb`, UTC, runs only while a `bin/jobs` is up), and
     a "Check it works" item using `Monk::Jobs.run_scheduler!` in a test.
   - `jobs/agents.md`: `Monk::Jobs.recurring` and where it goes under
     main calls; under pitfalls, cron is UTC and a new task first fires at
     its *next* occurrence, not on deploy.
   - `test/generators/jobs_test.rb`:
     - a new app gets `config/recurring.rb` (both migrations, in order:
       done in Phase 3);
     - the example tag `jobs-recurring` is reported;
     - with the example uncommented, the app's own tests pass and
       `Monk::Jobs.recurring_tasks` lists `hello_hourly` (proves the
       load order with a real class);
     - `test_the_apps_own_tests_pass_with_mail_and_auth_too` keeps
       passing with the new migration, which checks it applies.
   - `docs/guides/scaffolding.md`: the jobs entry lists
     `config/recurring.rb`, the second migration and the example.

7. **Docs.**
   - ADR 0016: why the scheduler runs on the job-process tick with one
     checkpoint row per task. Records the option tables above and
     decisions 5–8. Point the migration's header comment at it (it names
     this plan for now, which an app doesn't have).
   - `CONTEXT.md`: the Language terms above. Update the "Stager" entry,
     which currently says Monk has no recurring jobs.
   - `docs/guides/jobs.md`: a "Recurring jobs" section covering
     declaring, cron syntax, UTC only, missed runs, overlap,
     `skip_if_pending`, changing a schedule, adding the migration to an
     existing app, and testing. Remove "recurring (cron) jobs" from
     "What's not here".
   - **The jobs part of the 0.22 upgrade guide** (`docs/guides/upgrading.md`,
     one section per release; the guide itself belongs to the release
     branch, which adds the auth steps). For an app that already has
     jobs:
     1. add the `config/recurring.rb` line at the end of `config/load.rb`
        (`monk help base --file config/load.rb`);
     2. copy `config/recurring.rb` (`monk help jobs --file config/recurring.rb`);
     3. copy both halves of the migration under a new timestamp
        (`monk help jobs --file db/migrate/x_create_recurring_tables.up.sql`,
        and `.down.sql`), then `bin/migrate`. Until then, `bin/jobs`
        refuses to start with tasks declared, and the app's tests that
        call `Monk::Jobs.clear!` fail on the missing table;
     4. optionally, the new `SETUP.md` and `AGENTS.md` jobs sections.
     An app made with 0.22 needs none of this. The CHANGELOG entry links
     here.
   - README feature table and CHANGELOG.

## Explicitly out of scope

- **Time zones.** Possible later without a gem: Ruby finds the next
  matching local wall-clock time, and Postgres converts it with its own
  zone database (`AT TIME ZONE`).
- Running every missed occurrence (catch-up), and per-task choices about
  missed runs.
- Interval syntax (`every 300`), cron with seconds, month and day names.
- Schedules stored in the database or edited at runtime, and any UI.
- Overlap control beyond `skip_if_pending` (general concurrency limits
  and unique jobs remain their own features).
- Per-task queue, priority or `max_attempts` overrides: use a subclass
  of the job.
- A switch to turn the scheduler off in some job processes.

## Open questions

- **Passing the occurrence to the job.** A daily report usually wants
  "which day", not "when did it run". An option like `occurrence_arg:
  true`, appending the ISO 8601 occurrence to the args, is cheap. Left
  out of Phase 2 (2026-10-12): nothing needs it yet, and adding it later
  changes no stored data.
- **Pruning rows of removed tasks** (decision 10): a startup pass that
  deletes keys no longer declared would break a rolling deploy, where
  old processes still declare them. Leave it to a manual step unless it
  becomes a problem.
- **Log volume.** `:skipped_pending` on a task that runs every minute
  could be noisy at info level. Revisit after real use.

## Risks worth watching

- **Rolling deploys that change a schedule** (decision 8) can miss one
  occurrence.
- **Slow or unavailable Postgres.** Occurrences that come due during the
  outage are covered by "missed runs fire once" once it's back. An outage
  shorter than one occurrence interval only delays the run.
- **The cron parser is ours.** The edge cases (leap days, both day
  fields restricted, steps on ranges) need the tests in Phase 1 to be
  thorough, since there's no library behind it.
