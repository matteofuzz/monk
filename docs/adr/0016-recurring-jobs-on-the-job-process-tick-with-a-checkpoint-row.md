# Recurring jobs are enqueued by every job process's supervisor tick, deduplicated by one checkpoint row per task

An app wants work run on a schedule: purge expired sessions every night, send a digest every Monday. `Monk::Jobs` already runs delayed jobs (`wait:`/`at:`), so a recurring job only needs something to call `enqueue` at the right moment. The hard part is doing that exactly once per occurrence when several `bin/jobs` processes run the same code and share no memory, under ADR 0013's constraints: no advisory locks (they pin a connection and break behind PgBouncer in transaction mode), no new gem, and finished jobs deleted, so `monk_jobs` can't remember that an occurrence already ran (`docs/history/plan-scheduled-jobs.md`).

We decided that the supervisor of every job process runs a scheduler step on its existing 1 s tick, next to the stager. Tasks are declared in code (`Monk::Jobs.recurring "purge_sessions", PurgeSessions, cron: "0 3 * * *"`, in `config/recurring.rb`) and checked when declared, so a mistake fails at boot. For each task the step computes the most recent occurrence of its cron expression, in UTC, and sends it to one SQL statement that keeps one row per task in `monk_recurring_tasks`: the task's key, its cron expression, and its checkpoint, the latest occurrence handled. The statement moves the checkpoint forward with a compare-and-set (only if it is older than this occurrence, and only if the occurrence has arrived by the database clock) and, in the same statement, inserts the job. Of several processes asking about the same occurrence, row locking lets exactly one move the checkpoint and enqueue; the others find it already handled. Each process also remembers the occurrence it last handled per task, so it asks the database once per occurrence, not once a second.

Measured in the plan's Phase 0 on Postgres 16: 8 connections firing each of 1,000 occurrences together gave exactly 1,000 jobs, at about 0.5 ms a call.

## Rules that follow from the checkpoint

- **Missed runs fire once.** The scheduler only asks about the latest occurrence, so after downtime a task several occurrences behind fires once, and the skipped ones are logged. Running every missed occurrence was left out.
- **A new task doesn't fire on deploy.** A task with no row gets one with its checkpoint at the current occurrence and nothing enqueued. Otherwise every deploy that adds a daily task would run it at once.
- **A changed cron expression resets the checkpoint without firing.** Moving `0 3 * * *` to `0 4 * * *` at 10:00 would otherwise see today's 04:00 as missed and fire at once. The row stores the expression it was set under; on a mismatch the checkpoint is reset to the current occurrence. During a rolling deploy, old and new processes reset it back and forth, so one occurrence inside the overlap can be missed.
- **Overlap is allowed unless asked otherwise.** A run starts even if the previous one is still pending, since jobs are at-least-once and already must be idempotent. `skip_if_pending: true` checks whether the job recorded for the checkpoint (`last_job_id`) still exists and isn't failed: finished jobs are deleted, so existing means not done. A skipped occurrence is used up, not delayed. There's no foreign key from `last_job_id` to `monk_jobs`: `ON DELETE SET NULL` would add a write to every job's finish, and a dangling id means exactly "done".
- **The scheduler has its own error handling, after the heartbeat.** An error only the scheduler hits must not stop the heartbeat, or other processes would prune this one as dead.

## Considered Options

Who triggers the enqueue:

- **External cron** (crontab, platform cron, a Kubernetes CronJob) running a script (rejected: different on every platform, the schedule lives outside the app, the app boots on every run, there's nothing like it in development, and it can't be tested)
- **Jobs that enqueue their own next run** (rejected: someone has to enqueue the first one, deploys add duplicates, the chain breaks for good when a run fails, and start times drift)
- **The supervisor tick of every job process, deduplicated in Postgres** (chosen: no new process, any live process can fire a run, and the database clock decides when a run is due)
- **A separate `bin/scheduler` process** (rejected: one more process to deploy, and nothing fires when it's down unless it deduplicates too, which is the chosen option in its own process)
- **One leader process scheduling from memory, chosen by an advisory lock** (rejected: advisory locks are ruled out, a new leader leaves a gap, and missed runs need saved state anyway)

How the database deduplicates:

- **One row per occurrence**, inserted with `ON CONFLICT DO NOTHING` before enqueueing, as Solid Queue does (rejected: the table grows forever and needs pruning, keeping a history nobody asked for)
- **One checkpoint row per task**, moved forward in the same statement as the enqueue (chosen: fixed size, it tells what was missed during downtime, and it is one narrow statement per step, like the rest of ADR 0013)
- **A unique key on `monk_jobs` (task, occurrence)**, as GoodJob does (rejected: a column on the hot narrow table, and wrong here: finished jobs are deleted, so the key stops protecting the moment the job finishes, and a process that computes the same occurrence late enqueues it again)

Also left out: time zones (cron is UTC only; Postgres's own zone database could add them later without a gem), seconds and month or day names in cron, schedules stored in the database or edited at runtime, and pruning rows of removed tasks (a startup pass would break a rolling deploy, where old processes still declare them).
