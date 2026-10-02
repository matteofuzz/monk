# Connection pools for short-lived Ractors (`Pg.pool`) — implementation plan

> **Historical document.** It records how this was planned or built at the time and may describe things that have since changed or shipped. For how Monk works today, see [`docs/guides/`](../guides/).

Status: designed 2026-10-02, revised after review the same day, not
started. Comes after [`plan-pg-reconnect.md`](plan-pg-reconnect.md): pool
workers use the ordinary `checkout`, so they need its reconnect fix, and
its rollback of a transaction left open (that plan's decision 8), since a
worker serves unrelated callers on one connection.

## The problem

`Monk::Persistence` gives each Ractor one connection, opened on its first
`checkout` and kept for the Ractor's life. That is right for long-lived
Ractors that run many queries: kino's workers, `Monk::Jobs`'s workers.

It is wrong for short-lived ones. `Monk::WebSocket::Server` runs every
socket in its own Ractor (`server.rb`, `#run`), and authenticating the
socket (`Monk::Auth.verify`, one `SELECT` on `sessions`) opens a
connection there. The socket then never touches the database again, but
it holds that connection for as long as it is open.

Measured on monk_talk's `bin/websocket_server` (2026-10-01, monkrb 0.19.0,
Postgres 16), with authenticated sockets:

| | Postgres connections |
|---|---|
| idle, after `listen!` | 1 (`LISTEN`) |
| 20 sockets open | 21 |
| 5 to 40 s after closing all 20 | 21: not released until the garbage collector finalizes them |

One connection per open page. With Postgres's default `max_connections`
(100) and the app's other processes, an app stops accepting sockets at
about 75 open pages. monk_talk's target is 15-25K concurrent sockets.
The full analysis is in monk_talk's `doc/database-connections.md`.

### Why not close the connection after authenticating

Opening a connection per handshake fixes the holding: measured, connect +
query + close is 13.6 ms against 0.35 ms on a held connection. But a
WebSocket server restart (every deploy) makes every page reconnect within
about half a second. At 25K pages that is ~680 connections opening at
once. It works up to roughly 2-3K open pages. It also doesn't cover Live
rules that query the database at each subscribe (monk_talk's V1 groups).

### Why not a classic pool

A thread pool lends connection objects to threads. Ractors can't do that.
On Ruby 4.0.6 with pg 1.6.3:

```
Ractor#send(conn, move: true) → Ractor::Error: can not move PG::Connection object
Ractor.make_shareable(conn)   → Ractor::Error: can not make shareable object for #<PG::Connection ...>
```

So the work goes to the connection instead: a few Ractors own the
connections, and other Ractors send them calls through ports.

## Verified before designing (2026-10-01/02)

| Question | Result |
|---|---|
| Can a pool Ractor run a transaction for another Ractor? | yes: a proc defined in a module body, sent through a port, ran `conn.transaction` in the pool |
| Can a proc that captures a local variable cross? | no: `Ractor::IsolationError`. A proc at a script's top level can't either (`self` is `main`). This is why calls name a method instead of carrying a block. |
| Do queries in different pool workers run in parallel? | yes: 4 × `pg_sleep(0.3)` through 4 workers took 306 ms; 8 took 613 ms (4 at a time) |
| What does the hop through a port cost? | nothing measurable: 0.30 ms on a held connection vs 0.26 ms through a pool |
| Can a caller wait with a timeout? | `Port#receive` takes no timeout; `Ractor.select(reply, timer_port)` works |
| Does a port keep one sender's order? | yes: 4 senders × 10,000 numbered messages, 0 out of order per sender |
| Does an ordinary exception cross? | yes, copied whole: class, own instance variables, `cause` |
| Does a `PG::Error` cross? | no: it holds `@connection` and `@result`, set by pg's C code. `Ractor::Error: can not copy PG::Connection object` |
| Does `dup` of a raised `PG::Error` keep what matters? | yes: class, message, backtrace, `cause`. Editing the copy leaves the original untouched. |
| After clearing `@connection` and replacing `@result` with a stand-in, does it cross? | yes: arrives as `PG::UniqueViolation`, `result.error_field(PG_DIAG_CONSTRAINT_NAME)` works, and `rescue PG::UniqueViolation` matches |
| Does the backtrace survive a port? | **no**: an exception sent through a port arrives with an empty backtrace (one returned as a Ractor's final value keeps it). `set_backtrace(e.backtrace)` before sending keeps it. |

## Decisions

1. **Worker Ractors plus a dispatcher** (kino's shape). Each worker is an
   ordinary Ractor with its own connection, opened by the ordinary
   `checkout`. `checkout`, transactions and the reconnect fix work in a
   worker exactly as anywhere else. The dispatcher exists because a port
   can only be read by the Ractor that created it, so workers can't share
   an inbox. The alternative was one Ractor running N threads with a
   connection each. It was rejected because it would need a second way for
   `checkout` to find a connection, and it runs all Ruby work on one core.
2. **A call names a method; it doesn't carry a block.** The caller sends
   the receiver (a module or class, always shareable), the method name and
   the arguments. A worker calls `receiver.public_send(name, *args, **kwargs)`.
   The method's own `checkout` gets the worker's connection. Models don't
   change and don't know where they run:

   ```ruby
   Contacts.include?(owner, email)                                                  # here, on this Ractor's connection
   Monk::Persistence::Pg.pool(:auth).call(Contacts, :include?, owner, email)        # in the pool
   ```
3. **Two methods.**
   - `call(receiver, name, *args, **kwargs)` waits for the result, up to
     the pool's `timeout`. It returns the method's value or re-raises its
     exception.
   - `call_async(receiver, name, *args, **kwargs)` waits only for the
     dispatcher to accept the call, a few microseconds. It raises if the
     call can't be accepted: queue full, pool not started, dispatcher dead.
     A failure while the call runs is logged with `Monk::Log.error`,
     since nobody is waiting for it.

   Everything after the method name belongs to the target method.
   `call` and `call_async` take no options of their own, so they never
   steal a keyword argument from the target method.
4. **Named pools, declared in config, started where they're used.**

   ```ruby
   # config/persistence.rb (every process loads it)
   Monk::Persistence::Pg.register(:primary, host: ..., dbname: ...)
   Monk::Persistence::Pg.pool(:auth, size: 4, timeout: 2)
   Monk::Persistence::Pg.pool(:notify, size: 1)

   # only in the process that uses them
   Monk::Persistence::Pg.start_pools!(:auth)
   ```

   - `pool(name, db: :primary, size: 4, timeout: 5, queue: 1000)` with
     arguments declares a pool. Nothing connects yet.
   - `start_pools!(*names)` starts them, in the main Ractor only.
   - `pool(name)` with no other arguments returns the started pool's
     handle: a frozen value holding the name, the options and the
     dispatcher's inbox port. It can be read from any Ractor and kept in
     a constant.
   - Pool names are separate from database names, so one database can
     have several pools (`:auth` in parallel, `:notify` in order).
   - Monk's own options take the name, as `db_name:` does:
     `Server.new(db_pool: :auth)`, `Live.authorize(..., db_pool: :auth)`.
   - Running handles are published by replacing a frozen Hash from the
     main Ractor (`@running = Ractor.make_shareable(@running.merge(...))`),
     so `start_pools!` works before or after `Monk.freeze!`.
   - Declared options are read from workers and callers, so
     `freeze_registry!` makes them shareable along with `@configs`: the
     same trap an unfrozen `@configs` already hit.
5. **Connect at start.** `start_pools!` returns once every worker has its
   connection, and raises if Postgres is unreachable, the same promise
   `Monk::Live.listen!` makes. Processes that don't start a pool hold no
   pool connections.
6. **Order comes from size.** A pool of `size: 1` runs calls one at a
   time: one sender's calls in the order it made them, different senders'
   calls in the order they reach the dispatcher. A pool larger than 1 runs
   calls in parallel, in no particular order. No `ordered:` flag; the
   guide states the rule. Where Monk itself depends on order (the
   `PgFanout` publisher, phase 8), it requires a pool of size 1 and raises
   otherwise.
7. **Errors keep their class.**
   - An exception that can be copied is sent as is.
   - When the copy fails (a `PG::Error`): `dup` it, set `@connection` to
     `nil`, and replace `@result` with a frozen stand-in. The stand-in
     holds the diagnostic fields (SQLSTATE, schema, table, column,
     constraint, detail, hint) and answers `error_field(code)`. The same
     treatment applies to its `cause`.
   - The backtrace is set as strings before sending (a port drops it
     otherwise). On the caller's side it becomes the worker's frames, a
     marker line, then the caller's frames.
   - `rescue PG::UniqueViolation` works the same in a direct call and a
     pool call. What a pool call loses is only `e.connection`, which is
     useless across Ractors anyway, and `e.result` being a real
     `PG::Result`.
   - The stand-in answers `error_field`, plus the read-only methods that
     need no connection and that apps use on an error's result
     (`error_message`, `result_status`/`res_status`). Anything else
     raises `NoMethodError`, and the guide says so.
   - Wrapping errors in a pool error class (as `Ractor::RemoteError` does)
     was rejected: `rescue PG::UniqueViolation` would silently stop
     matching when a call moves into a pool.
8. **Return values are copied.** They must be data: strings, numbers,
   arrays, hashes, frozen `Data` values. A value that can't be copied
   (a `PG::Result`) becomes an error that names the method: "`Contacts.list`
   returned a `PG::Result`, which can't leave the pool: return rows as
   data". Large results cost a copy; a pool is for small results.
9. **Stalls fail fast and leave no backlog.**
   - **Timeout** (`timeout:`, default 5 s, the same as `checkout`'s): a
     `call` raises `Monk::PersistenceTimeoutError` when it passes.
   - **Calls nobody waits for are skipped.** Each `call` carries a
     deadline. When a worker frees up, the dispatcher discards queued
     calls past their deadline instead of running them. `call_async` has
     no deadline and always runs.
   - **Queue limit** (`queue:`, default 1000 per pool): when that many
     calls are waiting, `call` and `call_async` raise
     `Monk::PoolFullError` at once. Normally 4 workers clear
     1000 calls in under 0.1 s, so a full queue means a stalled database,
     not a busy one.
10. **A call made from inside a pool worker runs inline**, on the
    worker's own connection, instead of queueing on its own pool. A full
    pool waiting on itself would never finish. Inline, it has the same
    limit as a direct call: if its `checkout` targets the database of a
    `checkout` block still open around it, it times out after 5 s, because
    `checkout` isn't reentrant (`persistence-evolutions.md`, item 3). The
    guide mentions it.

## How it works

```
caller Ractor ──[receiver, name, args, kwargs, reply port, deadline]──▶ dispatcher
                                                                           │ idle worker? hand it over
                                                                           │ none? queue (≤ queue:) or reply :full
                                                                           ▼
                                                                   worker Ractor (own connection)
                                                                     receiver.public_send(name, ...)
caller ◀────────────── [:ok, value] or [:error, exception] ─────────── reply port
                                                                     then tells the dispatcher it's idle
```

- **The dispatcher** owns the inbox port, the queue and the list of idle
  workers. It replies `:full` itself, and acknowledges `call_async` calls.
- **Timeouts are the dispatcher's job.** A ticker (as in
  `Monk::Jobs::Runtime`) lets it reply `:timeout` to a caller whose
  deadline passed, whether its call is queued or running. A caller just
  waits on its reply port, with no timer thread per call. Each call has
  its own reply port, so a late answer can't reach a later call.
- **Late answers.** After a `:timeout`, the worker still finishes and
  replies to a port nobody reads. The caller closes its reply port once
  it has an answer, whichever came first, and the worker rescues
  `Ractor::ClosedError` when replying, so a late answer is dropped instead
  of left waiting in the port.
- **Workers** loop: receive a call, run it, reply, report idle. A
  worker's connection follows the ordinary per-Ractor rules, including
  `plan-pg-reconnect.md`'s check and reset.
- **A worker that dies** (a bug, not an exception from the called method,
  which is caught) is noticed through `Ractor#monitor`, logged, and
  replaced. Its in-flight caller gets its timeout.

## Phases

Small red → green slices against a real Postgres, as in the other plans.

1. **Declaration.** (Done. The errors follow the existing top-level
   persistence errors: `Monk::UnknownPoolError` (never declared) and
   `Monk::PoolNotStartedError`; phase 4's is `Monk::PoolFullError`.
   `pool_config(name)` returns a declaration's frozen `Pool::Config`.
   Declaring a name twice or passing an unknown option raises. Since
   `pool(:auth)` with no options is a lookup, the "never declared" error
   shows how to declare one, so a config line with all defaults written
   as `pool(:auth)` fails at boot with a clear message.) `pool(name, ...)` validates its options (positive
   `size`, `timeout`, `queue`; `db:` must be registered) and stores them.
   `pool(:missing)` raises "never declared". `pool(:declared)` before
   `start_pools!` raises "declared but not started in this process".
   After `Monk.freeze!`, a worker Ractor can read a pool's options.
   `reset!` clears pools.
2. **Start and `call`.** `start_pools!` spawns the dispatcher and workers,
   waits for their connections, and raises if Postgres is unreachable (a
   port nothing listens on). `call` with positional and keyword arguments
   returns the value. A connection count shows `size` connections, however
   many caller Ractors call.
3. **Errors and return values.** Ordinary exceptions arrive whole. A
   `PG::UniqueViolation` arrives with its class, message, `cause`,
   `error_field` and a backtrace showing both sides. A `PG::Result` return
   value raises the named error. The stand-in's `error_message` works;
   other `PG::Result` methods raise `NoMethodError`.
4. **Timeouts and the queue.** With every worker stuck on `pg_sleep`: a
   `call` raises after `timeout`; a queued call whose caller gave up is
   never run (a counter in the method stays unchanged); with `queue: 2`,
   the third waiting call raises `PoolFullError`. A call that times out
   while running: its worker's late reply to the closed port doesn't
   crash the worker, and the worker serves the next call.
5. **`call_async`.** It returns once accepted, raises when the queue is
   full or the pool isn't started, and logs a failure inside the method.
   With `size: 1`, a sender's calls run in its order (numbered writes read
   back in sequence).
6. **Inside a worker, and a dying worker.** A method that calls its own
   pool runs inline. A worker killed mid-call is replaced, and the pool
   keeps serving.
7. **`Monk::WebSocket::Server.new(db_pool:)`.** Authentication runs
   `Monk::Auth.verify` in the pool (and the `reverify_interval` checks
   too). The monk_talk measurement repeated: with 20, then 1,000 open
   sockets, the server holds `size` connections plus `LISTEN`. Socket
   Ractors open none.
8. **`Monk::Live.authorize(..., db_pool:)`.** A rule's body runs in the
   pool. Rules are already shareable procs, so nothing new is asked of
   apps.
9. **The `PgFanout` publisher through a pool of size 1.** It replaces one
   publisher connection per Ractor that pushes. A pool larger than 1
   raises at configuration, naming the ordering rule. This needs a
   constructor change: `PgFanout.new(registry, pg_opts:)` takes raw
   connection options, while a pool's `db:` is a registered database
   name. Add `PgFanout.new(registry, db_pool: :notify)`, and keep
   `pg_opts:` for the per-Ractor publisher; passing both raises.
10. **Docs.**
    - `docs/guides/persistence.md`: a "Pools" section covering when to use
      one (short-lived Ractors, work that shouldn't wait), the rules
      (receiver and method name, data in and out, no caller context,
      timeouts don't undo writes, order only at size 1), and the options.
    - `docs/guides/websocket.md` and `live.md`: `db_pool:`.
    - The boot line lists running pools.
    - CHANGELOG.
11. **Load.** A reconnect storm: N authenticated sockets reconnecting
    together against a pool of 4, measuring how long they take to settle
    and the peak queue length. That decides the default `size` and
    whether one dispatcher keeps up. Also the publisher: a single size-1
    lane at ~0.3 ms per `pg_notify` tops out near 3K notifies/s per
    process, for every `Live.patch` of every web worker. Measure it under
    load; if it falls short, that's the case for "order per key" below.

## Open questions

- **A caller whose dispatcher has died.** Callers rely on the dispatcher
  for timeouts, so a dead dispatcher would leave them waiting. Options: the
  process that started the pool monitors the dispatcher and restarts it,
  or callers keep a long-stop timer of their own. Leaning towards the
  first: the main Ractor already monitors workers, and a timer per caller
  brings back the per-call timer the design avoids. Decide in phase 6.
- **Per-call options.** Options are set per pool. If a real case needs a
  different timeout for one call, add `pool(:auth).with(timeout: 10)`,
  which returns a new handle, rather than options on `call`.
- **Order per key.** `call_async(..., key: topic)` could send calls with
  the same key to the same worker: ordered per key, parallel across keys.
  That would let the publisher pool grow past size 1. Only if phase 11
  shows a single lane can't keep up.
- **A generic owner primitive.** The same shape (a few Ractors own a
  client, others send them calls) fits the Redis publisher, reused SMTP
  connections for `Monk::Mail`, and kept-alive HTTPS for `Monk::Storage`.
  If a second case is built, extract the dispatcher from `Pg` rather than
  copying it.
- **Reentrant `checkout`** (`persistence-evolutions.md`, item 3) is
  related but separate. The pool doesn't need it.
