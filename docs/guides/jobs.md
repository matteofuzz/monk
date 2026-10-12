# Background jobs — `Monk::Jobs`

Work that shouldn't hold up a request (sending mail, calling another
service, crunching numbers) goes on a queue in Postgres and runs in a
separate job process, `bin/jobs`, on a pool of worker Ractors. Opt-in:
`require "monk"` never loads it. Postgres is the only thing it needs; no
Redis, no other gem. The design, and the measurements behind it, are in
[`docs/adr/0013-jobs-narrow-state-table-plus-payloads.md`](../adr/0013-jobs-narrow-state-table-plus-payloads.md).

`monk add jobs` writes everything below for you, and adds `postgres` if the
app doesn't have it (see [`scaffolding.md`](scaffolding.md)).

```ruby
# app/jobs/send_receipt.rb
class SendReceipt < Monk::Job
  def self.perform(order_id)
    order = Order.find(order_id)
    return unless order # deleted since it was enqueued

    Monk::Mail.deliver(to: order[:email], subject: "Your receipt", text: "Order #{order_id}: thanks!")
  end
end
```

```ruby
# a route, in app/app.rb
post("/orders") do
  id = Order.create(email: params[:email])[:id]
  SendReceipt.enqueue(id)
  json(id: id)
end
```

```bash
bin/server    # enqueues
bin/jobs      # runs them, in another terminal (or another container)
```

## Before anything else: jobs may run more than once

Delivery is **at-least-once**. If a job process is killed mid-job
(`kill -9`, an out-of-memory kill, a lost machine), another job process
runs that job again once the dead one has gone quiet for two minutes. A
job that ran to the end but couldn't record that it finished (the
database went away at that moment) runs again too. So make every job safe
to repeat:

- Check before acting (`return if order[:receipt_sent_at]`), and record
  that it happened in the same transaction as the work, where you can.
- For a call to another service, pass an idempotency key the service
  understands (the job's own arguments are usually a good one).

## Configuring

```ruby
# config/jobs.rb
require "monk/jobs"
require_relative "persistence"

Monk::Jobs.configure(db_name: :primary)
```

`db_name:` is a database registered with `Monk::Persistence::Pg`. The
app's own database is the default, and usually the right one: it's what
lets you enqueue inside the app's own transaction (below). When to move
the queue elsewhere is covered in [Keeping the queue healthy](#keeping-the-queue-healthy).

Every job class has to be loaded in both processes: the web process
enqueues by class, and the job process finds the class again by its name.
Job classes live in `app/jobs/`, and `config/load.rb` loads them after
`config/jobs.rb`. `config.ru` and `bin/jobs` both require `config/load`,
so both processes have every job (see [`scaffolding.md`](scaffolding.md),
"Where code goes").

The queue's three tables come from the migration `monk add jobs` writes
(`db/migrate/<timestamp>_create_jobs_tables.{up,down}.sql`, versioned when
it's added). `bin/setup_db` applies it like any other.

## Defining a job

```ruby
class SendReceipt < Monk::Job
  queue "mailers"   # default "default"
  priority(-10)     # lower runs sooner; default 0
  max_attempts 3    # default 5
  timeout 30        # seconds one run may take; default: no limit
  never_retry OrderCancelledError  # fail at once on these; see "When a job fails"

  def self.perform(order_id)
    # ...
  end
end
```

- **A class with `def self.perform`**, not a block: a class can be used
  from any Ractor as it is. Define `perform` with `def`, not
  `define_method`, which only works in the Ractor that defined it
  ([`../design/ractor.md`](../design/ractor.md)).
- **Settings are inherited**, so shared ones can go on the app's own base
  class (`class MailerJob < Monk::Job; queue "mailers"; end`). A
  subclass's `never_retry` adds to its parent's list.
- **Sending mail?** Often you don't need a job class of your own:
  `Monk::Mail.deliver_later` queues the email as a job
  ([`mail.md`](mail.md#sending-from-a-job-deliver_later)). For login
  links, see [`auth.md`](auth.md#sending-the-magic-link-from-a-job).
- **Every job runs in a worker Ractor.** Everything it touches must work
  there: `Monk::Persistence`, `Monk::Mail`, `Monk::Log` and
  `Monk::StateRactor` do. A gem that keeps mutable state in a module or
  class variable doesn't, and a constant holding a mutable object can't
  even be read (freeze it, or `Ractor.make_shareable` it). Your tests
  catch this, because `drain!` runs jobs in a Ractor too ([Testing](#testing-jobs)).

## Enqueueing

```ruby
SendReceipt.enqueue(order_id)                        # as soon as a worker is free
SendReceipt.enqueue(order_id, wait: 60)              # no sooner than 60 seconds from now
SendReceipt.enqueue(order_id, at: Time.now + 3600)   # no sooner than then
Monk::Jobs.enqueue(SendReceipt, order_id)            # the same thing
```

It returns the job's id. It works from any route (routes run in worker
Ractors) and from anywhere else, after `Monk::Jobs.configure`.

**Arguments must be plain JSON values**: Strings, Integers, finite
Floats, `true`/`false`/`nil`, and Arrays or String-keyed Hashes of those.
They're stored as JSON and handed to `perform` in another process, so
anything that wouldn't come back unchanged is refused when you enqueue,
with an error naming it (`Monk::Jobs::InvalidArgumentsError: args[0]["user"]["joined"]
is a Time ...`). Pass an id rather than a record (it may have changed by
the time the job runs), an ISO 8601 String rather than a `Time`, String
keys rather than Symbols.

`wait:` and `at:` go by the database's clock, not the app server's.

### Inside the app's own transaction

Pass the connection you're already using, and the job commits or rolls
back with your own writes: no job for an order that failed to save, and
no order without its job.

```ruby
Monk::Persistence::Pg.checkout(:primary) do |conn|
  conn.transaction do
    id = conn.exec_params("INSERT INTO orders (email) VALUES ($1) RETURNING id", [email]).getvalue(0, 0)
    SendReceipt.enqueue(id, conn: conn)
  end
end
```

Inside a `checkout` block, `conn:` isn't optional: without it `enqueue`
checks out the same connection again and waits on itself until it times
out (`Monk::PersistenceTimeoutError`).

## Running jobs: `bin/jobs`

`bin/jobs` is the job process. It requires `config/load`, as the web
process does, so a job sees every config and all of `app/` (models,
mailers, other jobs), and never boots the app itself. Then it runs until
`TERM` or Ctrl-C:

- **Worker Ractors** (`JOBS_WORKERS`, default 5) each take a job, run it,
  and take the next. Each has its own database connection.
- **Queues** (`JOBS_QUEUES`, comma-separated, default `default`) are
  served in the order given: a worker only takes from a later queue when
  the earlier ones have nothing ready. Within a queue, a lower `priority`
  goes first, then whichever job has been due longest.
- **A supervisor** in the main Ractor makes scheduled jobs that have come
  due claimable and restarts any worker that died, once a second. Every
  15 seconds it also records that this process is alive, and releases the
  jobs of any process that has gone quiet.

On `TERM` each worker finishes the job in hand, for up to 25 seconds, then
the process exits. Any job still running after that is put back for
another process to run. Give the platform a longer stop window than 25
seconds (Docker's default is 10); see [`deploying.md`](deploying.md).

A process that loses its database connections (Postgres restarting, a
failover) reconnects: workers are restarted with fresh connections, and
the supervisor retries on its next tick.

### When a job fails

A job that raises is retried, after a pause that grows with each attempt:
16 s, 31 s, 96 s, 271 s, 640 s … (`attempts ** 4 + 15`). After
`max_attempts` it's marked **failed** and stays in the queue, with its
error, until you retry or discard it. Some errors never retry, since
another attempt can't help: an unknown job class (a job enqueued by a
newer deploy, or a renamed class) and a missing `self.perform`. A job that
runs past its `timeout` fails like any other error and is retried.

For errors of your own that no retry will fix (a declined card, a record
that's gone), list them with `never_retry`, and the job fails on the first
one instead of spending its remaining attempts:

```ruby
class ChargeCard < Monk::Job
  never_retry CardDeclinedError, OrderCancelledError
end
```

A listed class's subclasses count too, the way `rescue` matches.

```ruby
Monk::Jobs.retry_failed(id)     # back to the queue, with fresh attempts
Monk::Jobs.discard_failed(id)   # gone
```

There's no dashboard. The state is in plain tables, so SQL is the way in:

```sql
-- how many jobs are in each state
SELECT state, count(*) FROM monk_jobs GROUP BY state;

-- failed jobs, newest first, with what went wrong
SELECT j.id, p.job_class, p.args, j.attempts, p.last_error
FROM monk_jobs j JOIN monk_job_payloads p ON p.job_id = j.id
WHERE j.state = 'failed' ORDER BY j.id DESC;

-- job processes, and when each last checked in
SELECT id, hostname, pid, last_heartbeat_at FROM monk_processes;
```

Every failure is also logged to `log/<env>.log`, with the job's class, id,
attempt, the error, and what happens next.

### Timeouts

With `timeout 30`, a run that takes longer is interrupted and counts as a
failure. The worker then resets its connection to the queue's database,
because an interrupted query keeps running on the server and the
connection's next query would wait for it. A query the job left running
on a *different* registered database isn't reset: that connection stays
busy until its query ends. For database-heavy jobs, a `statement_timeout`
on the connection stops the query itself:

```ruby
conn.exec("SET statement_timeout = '25s'")
```

### Sizing and tuning

The runtime's settings, for a `bin/jobs` of your own
(`Monk::Jobs::Runtime.new(**settings).run`, after `require "monk/jobs/runtime"`):

| Setting | Default | What it sets |
|---|---|---|
| `workers:` | 5 | Worker Ractors, so how many jobs run at once in this process |
| `queues:` | `["default"]` | The queues served, in order |
| `poll_interval:` | 1.0 | Seconds an idle worker waits before looking for work again, so how long a new job can wait for an idle worker (about half of it on average) |
| `tick_interval:` | 1.0 | Seconds between the supervisor's rounds, so how late a scheduled job or a retry can start |
| `heartbeat_interval:` | 15 | Seconds between this process's check-ins (and its checks for dead processes) |
| `process_timeout:` | 120 | Seconds of silence after which another process takes back a process's running jobs |
| `shutdown_timeout:` | 25 | Seconds a stop waits for jobs in flight |

- **Faster pickup:** lower `poll_interval`. An idle check is one small
  query, so `0.2` with a handful of workers is still light. Monk doesn't
  wake workers with Postgres `NOTIFY`: it would save only that fraction
  of a second, and its commit lock gets costly exactly when the app is
  busy (ADR 0013).
- **More throughput:** more `JOBS_WORKERS` for CPU-bound jobs, up to about
  the number of cores. For jobs that mostly wait on the network, more
  processes. Each worker runs one job at a time.
- **Mail first:** `monk new` with mail and jobs sets
  `JOBS_QUEUES=mailers,default`, so emails (on the `mailers` queue) go out
  before other work waiting in the queue.
- **Separating slow work from urgent work:** run a second `bin/jobs` with
  its own `JOBS_QUEUES` (e.g. one process for `mailers`, another for
  `default,reports`), so a backlog of slow jobs never delays a login email.

## Testing jobs

In tests, jobs run right in the test, on the app's test database. No job
process is needed:

```ruby
# test/test_helper.rb (as monk new's SETUP.md writes it)
require_relative "../config/load" # config/jobs.rb, then app/jobs/
```

```ruby
class OrdersTest < Minitest::Test
  def teardown
    Monk::Jobs.clear!
  end

  def test_placing_an_order_sends_the_receipt
    SendReceipt.enqueue(order_id)

    assert_equal 1, Monk::Jobs.drain!
    # ... assert on what the job did
  end
end
```

- **`Monk::Jobs.drain!`** runs every job that's due, including jobs those
  jobs enqueue, until none is left, and returns how many ran. Jobs
  scheduled for later stay queued. Nothing is retried: the first job that
  raises is marked failed and its error is raised in your test, as the
  job's own error.
- **Each job runs in a fresh Ractor**, as it would in `bin/jobs`, so a job
  that only works outside a Ractor fails in the test instead of in
  production. When a test needs to see a job's side effects in the test's
  own Ractor (a test double, say), use `Monk::Jobs.drain!(in_ractor: false)`.
- **`Monk::Jobs.clear!`** empties the queue between tests, failed jobs
  included. It refuses to run unless `MONK_ENV=test`
  (`Monk::Jobs::ClearOutsideTestsError`), since anywhere else it would
  empty a real queue.

The test database needs the jobs tables: `DB_NAME=my_app_test bin/setup_db`
applies them along with the rest.

## Keeping the queue healthy

Every job is a row that's written, updated and deleted within seconds.
Postgres cleans up the old row versions this leaves behind (vacuum), and
the queue stays fast as long as that keeps up. The migration already tunes
vacuum for `monk_jobs`; what can stop it is outside the queue.

**Long transactions are the main risk.** While any transaction on the same
database stays open (a slow report, a migration, a session left idle
inside `BEGIN`), Postgres can't clean up anything that changed after it
began. Dead rows pile up at the front of the queue's index, and every
claim gets slower until that transaction ends. Measured: with a
transaction held open for two and a half minutes, claiming a job went
from about 2 ms to about 13 ms, and throughput halved. Ways out, from
cheapest:

- **Close idle transactions automatically:** `ALTER DATABASE my_app SET
  idle_in_transaction_session_timeout = '60s';`
- **Keep long analytical queries off this database:** a read replica,
  or a separate reporting database.
- **Give the queue its own database.** Postgres only holds back cleanup
  for transactions on the *same* database, so a queue on its own database
  (on the same server is fine) isn't slowed by the app's long
  transactions at all. Measured: no slowdown at all with the same long
  transaction running on the app's database.

### Moving the queue to its own database

1. Create the database, and register it in `config/persistence.rb` next
   to `:primary`:
   ```ruby
   Monk::Persistence::Pg.register(:queue, host: ..., dbname: "my_app_queue", ...)
   ```
2. Configure jobs on it: `Monk::Jobs.configure(db_name: :queue)`.
3. Move the jobs migration pair out of `db/migrate` into a directory of
   its own (say `db/migrate_queue`), and apply it to the queue database:
   ```ruby
   Monk::Persistence::Pg::Migrator.new(db_name: :queue, dir: "db/migrate_queue").migrate!
   ```
   `bin/setup_db` only migrates `:primary`, so add this line to it.
4. **Stop passing `conn:` from `:primary`.** A job and the app's data can
   no longer commit together, since they're in different databases. Pass
   a `:queue` connection or none. Enqueue after the app's transaction
   commits, and accept that a crash between the two loses the job. That's
   the trade-off for the isolation.

Cleanup that spans the whole server still affects every database on it:
a replica that has fallen behind (a replication slot, or
`hot_standby_feedback` while the replica runs a long query) holds back
cleanup everywhere.

## What's not here

Deliberately left out of the first version
([`../history/plan-jobs.md`](../history/plan-jobs.md)): recurring (cron)
jobs, unique jobs, limits on how many of a kind run at once, pausing a
queue, batches, keeping finished jobs, a dashboard, a Redis backend, and
more than one job at a time per worker. Finished jobs are deleted; failed
ones stay until retried or discarded.
