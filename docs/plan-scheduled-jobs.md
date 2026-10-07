# Recurring jobs (`Monk::Jobs.recurring`) — implementation plan

Branch: `main_dev/scheduled_job`. Designed 2026-10-06. Nothing built yet.
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

2. **Declared in `config/jobs.rb`, keyed explicitly.** For example:

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

   Declarations are stored in a list, and `freeze_registry!` makes that
   list shareable. Queue, priority and `max_attempts` come from the job
   class, as with any `enqueue`.

3. **Cron syntax, UTC only.** Our own small parser, `Monk::Jobs::Cron`,
   with no dependency:
   - Five fields: minute, hour, day of month, month, day of week.
   - In each field: `*`, numbers, lists (`,`), ranges (`-`) and steps
     (`/`). Day of week runs 0–7, with both 0 and 7 meaning Sunday.
   - Shortcuts: `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`.
   - When both day of month and day of week are restricted, a day
     matching either one counts, as in Vixie cron.
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

   The open detail is how the statement records `last_job_id` without
   updating the same row twice. The plan is to take the id from the
   identity sequence first and insert with `OVERRIDING SYSTEM VALUE`, as
   `HEARTBEAT_SQL` already does. Phase 0 confirms this, and falls back to
   a short transaction (update, enqueue on the same connection, set
   `last_job_id`) if the single statement turns out unclear.

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
   workers. The error names the migration file to copy, so the supervisor
   doesn't log a failure every second instead. The startup log line also
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
   - Migration `00000000000003_create_recurring_tables.up/down.sql` in
     the `jobs` template, and the matching table in the test schema.
   - `Adapters::Pg#fire_recurring` with one test per outcome of decision
     5, including `skip_if_pending` with a pending, a running, a failed
     and a finished previous job.
   - The checkpoint comes back from the statement so decision 6 can log
     it.
   - `clear!` empties the new table.
4. **Runtime integration.**
   - The scheduler step in `Runtime#tick`, with the per-process "last
     handled" Hash.
   - The table check and log line from decision 9.
   - A test that two `Runtime`s running against the same database
     enqueue each occurrence once.
   - A test that a database error during the scheduler step is logged and
     retried on the next tick.
5. **Testing helper.** `run_scheduler!(at:)` with its `MONK_ENV=test`
   guard, plus an end-to-end test: declare, initialize, advance, `drain!`.
6. **Scaffolding.**
   - `monk new --jobs` ships the new migration.
   - `config/jobs.rb` gets a commented `recurring` example.
   - `scaffold_jobs_test.rb` covers both.
7. **Docs.**
   - ADR 0016: why the scheduler runs on the job-process tick with one
     checkpoint row per task. Records the option tables above and
     decisions 5–8.
   - `CONTEXT.md`: the Language terms above. Update the "Stager" entry,
     which currently says Monk has no recurring jobs.
   - `docs/guides/jobs.md`: a "Recurring jobs" section covering
     declaring, cron syntax, UTC only, missed runs, overlap,
     `skip_if_pending`, changing a schedule, adding the migration to an
     existing app, and testing. Remove "recurring (cron) jobs" from
     "What's not here".
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
  true`, appending the ISO 8601 occurrence to the args, is cheap. Decide
  before Phase 2, or leave it for later.
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
