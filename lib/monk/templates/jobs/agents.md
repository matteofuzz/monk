## jobs

**Where:** `config/jobs.rb` (the queue lives in the `:primary` database),
job classes in `app/jobs/`, schedules in `config/recurring.rb`, `bin/jobs`
runs them.

**Main calls:** `class SendInvoice < Monk::Job` with
`def self.perform(id)`; `SendInvoice.enqueue(id)`, `wait: 300`, `at: time`,
or `conn: conn` to enqueue inside your own transaction. Class settings:
`queue "mailers"`, `max_attempts 5`, `never_retry SomeError`. With mail:
`Monk::Mail.deliver_later(...)`; with auth:
`Monk::Auth::SendLoginLink.enqueue(email)`. Recurring, in
`config/recurring.rb` only:
`Monk::Jobs.recurring "key", JobClass, cron: "0 3 * * *", args: [...]`
(`skip_if_pending: true` to skip while the last run is pending).

**Test:** `test/jobs_test.rb`. In tests, `Monk::Jobs.drain!` runs every
enqueued job right away, each in a Ractor; `Monk::Jobs.clear!` in
`teardown` empties the queue. `Monk::Jobs.run_scheduler!(at: time)` runs
the schedules as if the clock read `time` (call it once to set the
checkpoint, then at the next occurrence).

**Pitfalls:**
- A job's arguments are stored as JSON: pass ids and plain values, never
  records or objects.
- A job may run more than once (its process was killed mid-job): make it
  safe to repeat.
- Jobs run in Ractors: the same shareability rules as routes.
- Cron is UTC. A new recurring task first fires at its next occurrence,
  not on deploy, and a missed run fires once, not once per occurrence
  missed. Keep a task's key when renaming its class.

**Examples:** `jobs-enqueue` in `app/routes/jobs.rb`, `jobs-recurring` in
`config/recurring.rb`; `app/jobs/hello_job.rb`
is a real, deletable demo job.
