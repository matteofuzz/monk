# Recovering from a dropped Postgres connection — implementation plan

> **Historical document.** It records how this was planned or built at the time and may describe things that have since changed or shipped. For how Monk works today, see [`docs/guides/`](../guides/).

Status: proposed 2026-10-01, revised after review 2026-10-02, not
started. Found while reviewing monk_talk's connection lifecycle on monkrb
0.19.0. Comes before [`plan-pg-pool.md`](plan-pg-pool.md), whose workers
rely on this plan's checkout probe and rollback.

## The problem

When Postgres drops a connection (a restart, a failover, an admin's
`pg_terminate_backend`, a network blip that closes the socket), the web
process never recovers. Every request that touches the database answers
`500` until the process is restarted.

Why: `Monk::Persistence::Registry#checkout` (`lib/monk/persistence.rb`)
opens one `PG::Connection` per Ractor on first use, memoizes it in
`Ractor.current[:monk_persistence]`, and hands out that same object
forever. Nothing checks it or resets it. A dead connection stays dead.

The same holds for the two connections `Monk::WebSocket::PgFanout` opens
itself:

- **The publisher** (`#publisher`, one per Ractor): every
  `Monk::Live.patch`/`batch` after the drop raises `PG::ConnectionBad`.
  The app's own data is saved, but no open page updates.
- **The `LISTEN` connection** (`#listen!`'s subscriber Ractor):
  `wait_for_notify` raises `PG::ConnectionBad`, nothing rescues it, and
  the Ractor ends. `Listeners.listening?` still says `true`, so the
  WebSocket server keeps accepting sockets that will never get another
  process's broadcast. Nothing is logged.

`Monk::Jobs` already recovers: the supervisor reconnects after errors
(`jobs/runtime.rb`), and a worker resets its connection after a job
timeout (`jobs/adapters/pg.rb`, `#reset_connection`).

A second, smaller gap made this hard to see: `Base#dispatch` turns an
exception with no `error` handler into a `500` and logs only
`GET /path -> 500 (0.3ms)`. The exception class and message are lost,
in development too.

## Reproduction (2026-10-01, Ruby 4.0.6, pg 1.6.3, Postgres 16)

Against monk_talk's `bin/server` (kino `:ractor`, 8 workers × 1 thread),
requesting a route that reads the database (`GET /auth/callback/<bogus>`):

```sh
docker exec <pg container> psql -U postgres -c \
  "select pg_terminate_backend(pid) from pg_stat_activity
   where datname = '<app db>' and pid <> pg_backend_pid()"
```

| | Responses | The server's connections in `pg_stat_activity` |
|---|---|---|
| before | 20 × `302` | 8, one per worker Ractor |
| after the kill | 20 × `500` | 0 |
| later | 20 × `500` | 0: it never reconnects |

In a script, the same in the main Ractor and in a worker Ractor:

```
before:          ok, backend pid 69462
after kill #1:   PG::ConnectionBad: PQconsumeInput() FATAL: terminating connection due to administrator command
after kill #2:   PG::ConnectionBad: PQsocket() can't get socket descriptor
status:          CONNECTION_BAD, from then on
```

`pg_terminate_backend` looks exactly like a server restart to the client:
the server sends a `FATAL` and closes the socket.

## What libpq tells us, measured

The fix rests on these, all checked on a real connection:

1. **A dropped connection can be detected at checkout without a round
   trip.** After the server closes it, `conn.status` still says
   `CONNECTION_OK`, but the socket is readable. The first
   `consume_input` reads the `FATAL` (no error, status still `OK`); the
   second reaches end of file, raises `PG::ConnectionBad`, and the status
   becomes `CONNECTION_BAD`. So the probe drains while the socket is
   readable:

   ```ruby
   def alive?(conn)
     return false unless conn.status == PG::CONNECTION_OK
     3.times do
       break unless IO.select([conn.socket_io], nil, nil, 0)
       conn.consume_input
     end
     conn.status == PG::CONNECTION_OK
   rescue PG::ConnectionBad
     false
   end
   ```

   | Case | `alive?` |
   |---|---|
   | healthy, idle | `true` |
   | after `pg_terminate_backend` | `false` |
   | idle with a pending `NOTIFY` (readable, but fine) | `true` |
   | after `conn.reset` | `true` |

   Cost: 10,000 probes on a healthy connection took 21.9 ms, about
   2 µs each, a zero-timeout `select` and nothing sent.

   **Revised in phase 2:** this probe races the server's close. The
   FATAL can arrive a moment before the end of file, so the second
   `select` sees nothing and the probe says alive. Run 10 times, the
   reconnect test failed 6. The shipped probe stops at the first
   `select`: an unreadable socket is alive, and a readable one (a FATAL,
   or a NOTIFY on a connection that LISTENs) gets an empty query, one
   round trip, which fails on a closed connection and leaves pending
   notifies queued. Healthy case: 1.1 µs per probe, 2.2 µs for an empty
   `checkout`. Stable over 20 runs.
2. **`conn.reset` works inside a worker Ractor** and keeps the
   connection object, so `type_map_for_results` (our `RESULT_TYPES`,
   json decoding) survives: `SELECT 1::int` returns an `Integer` after a
   reset.
3. **`wait_for_notify` raises `PG::ConnectionBad`** on a dropped
   `LISTEN` connection, so the subscriber loop can catch it.

## Decisions

1. **Check at checkout, reset if dead, never retry the block.**
   `checkout` runs `alive?` before yielding, and `conn.reset`s a dead
   connection. A block is never run twice. Monk can't tell whether a
   block's writes reached the server before the connection failed: an
   `INSERT` that committed, then a `SELECT` that hit the dead socket,
   would insert twice on a retry. The same goes for a failed `COMMIT`,
   whose outcome is unknown. Most drops happen while a connection is
   idle between requests, and the probe catches those, so most drops
   cost no failed request at all.
2. **A drop in the middle of a block still fails that request.** The
   error propagates as today (`500`). The next checkout in that Ractor
   finds the status `CONNECTION_BAD` and resets. At most one failed
   request per Ractor per drop, instead of every request from then on.
3. **If Postgres is still down, the reset raises, and the checkout
   raises with it.** Requests fail fast with `PG::ConnectionBad` rather
   than queueing. The next checkout tries again. No backoff in the web
   process: one `connect` attempt per request is the backoff.
   "Fail fast" needs a bound on the connect itself: with no
   `connect_timeout`, a reset to a host that doesn't answer (as opposed to
   one that refuses) waits indefinitely, while holding the Ractor's slot,
   so every other thread in that Ractor gets `PersistenceTimeoutError`
   too. `Pg#connect` merges `connect_timeout: 5` (the same as
   `checkout`'s timeout) into the options unless the app set one.
4. **The probe and the reset belong to the backend, not the Registry.**
   `Registry#checkout` calls two new backend hooks: `alive?(conn)` and
   `revive(conn)` (and `release(conn)`, decision 8). They default to
   "always alive" and no-ops, so the Registry stays backend-agnostic. `Monk::Persistence::Pg` implements
   them as above. `alive?` is public on `Pg` so `PgFanout` reuses it.
   `Registry#[]` hands out the connection without a checkout, so it skips
   the probe. Its one caller is `Jobs::Adapters::Pg#reset_connection`,
   which keeps its `cancel` (a timed-out job's connection is alive but
   busy) and resets through `revive`, so a connection is reset in one way
   only.
5. **The publisher probes too, with no retry.** `PgFanout#publisher`
   checks `alive?` and resets before each `pg_notify`. A retry after a
   failed `pg_notify` could deliver a patch twice (a doubled chat
   bubble), and a missed patch is already recovered by the client's
   resync.
6. **The `LISTEN` Ractor reconnects, then makes every page resync.**
   On `PG::ConnectionBad` it logs, reconnects with backoff (500 ms
   doubling to 30 s, like the browser client), and runs `LISTEN` again.
   Notifies sent while it was down are lost, and the browser can't see
   that gap: its `seq` counts what this server sent, and the server never
   received them. So after reconnecting, the subscriber closes every
   open socket with `1011`, which makes each client reconnect and resync
   (ADR 0011). The clients' jittered reconnect spreads the refetches.
   Any other exception in the loop (a malformed envelope, a failing
   `registry.broadcast`) is logged and that one notify is skipped. Today
   any exception ends the Ractor silently, and rescuing only
   `PG::ConnectionBad` would leave that path open: `listening?` true,
   nothing arriving, nothing logged.
7. **A `500` logs its exception.** When no `error` handler matched,
   `Base#dispatch` logs `GET /x raised PG::ConnectionBad: ...` at `error`,
   with the first 10 backtrace lines. When one did, it logs the same line
   at `info` with `(handled)` and no backtrace: the app chose the
   response, and an `error(NotFound) { halt 404 }` shouldn't fill the log
   with errors. The request line stays as it is. (Done in phase 1.)
8. **A checkout never hands out an open transaction.** A block that runs
   a raw `BEGIN` and raises leaves the connection in a transaction, and
   the next checkout in that Ractor would run inside it (`conn.transaction`
   already rolls back; raw `BEGIN` doesn't). `checkout`'s `ensure` runs
   `ROLLBACK` when the connection is alive and `transaction_status` isn't
   idle, through a third backend hook, `release(conn)`, a no-op by
   default. Minor today, but `plan-pg-pool.md`'s workers serve calls from
   unrelated Ractors on one connection, where a leaked transaction would
   reach the next caller.

## Phases

Small red → green slices, as in the other plans. The tests need a real
Postgres, like `persistence_test.rb` and `websocket_pg_fanout_test.rb`,
and drop connections with `pg_terminate_backend` from a second
connection. `pg_terminate_backend` returns before the client's socket is
guaranteed to be readable, so a checkout straight after it can still see
a healthy socket and fail on the query. Tests wait until the terminated
pid has left `pg_stat_activity` before checking out; otherwise they
flake.

1. **Log the exception behind a `500`.** `error_handling_test.rb`: a
   route that raises logs its class and message, with and without a
   handler.
2. **Backend hooks and the checkout probe.** (Done. `conn.reset` also
   reconnects a connection closed locally with `finish`, so
   `jobs_runtime_test.rb`'s job that lost its connection to make a
   worker's finish fail now recovers instead. It was renamed
   `CantFinish` and sets its session read-only instead, so the test
   still covers releasing a dead worker's job.) `persistence_test.rb`:
   - a checkout after `pg_terminate_backend` succeeds, on a new backend
     pid;
   - a block that raises `PG::ConnectionBad` mid-way propagates (no
     retry: a counter in the block is 1), and the next checkout works;
   - the json type map survives a reset;
   - with Postgres unreachable (a registered port nothing listens on, so
     the test doesn't stop the server), checkout raises
     `PG::ConnectionBad` and doesn't hang;
   - `connect_timeout` defaults to 5 and an app's own value wins;
   - `Jobs::Adapters::Pg#reset_connection` resets through `revive`, and
     the existing Jobs timeout tests stay green;
   - a block that runs a raw `BEGIN` and raises: the next checkout
     finds `transaction_status` idle, and the half-done write is gone;
   - the probe over TLS (`sslmode=require`, when the test server allows
     it): all the measurements above were on a plain socket, and TLS adds
     a buffer between `IO.select` and libpq.
3. **Same in a worker Ractor.** (Done. Phase 2 covered it with no change:
   the test fails with the probe stubbed out.)
   `persistence_ractor_integration_test.rb`:
   terminate a worker Ractor's connection, then the next checkout in that
   Ractor succeeds.
4. **Publisher.** (Done. The publisher also gets the `connect_timeout: 5`
   default, since its reset runs inside a request's `Live.patch`.)
   `websocket_pg_fanout_test.rb`: terminate the
   publisher's backend, then `broadcast` reaches another process's
   listener.
5. **Listener.** (Done. How it reaches every socket: `Registry#close_all`
   sends one `Monk::WebSocket::CloseRequest` value to each registered
   port, once per port even when a Live page holds several topics, and
   both relays (`Connection#relay_broadcasts`, `Live::Session#relay`)
   close their socket with its code. That exposed a latent bug in
   `Connection#close` when called from a thread other than the reader's
   (a relay, the reverify thread): `IO#close` waits for the blocked
   reader, the reader's cleanup kills the closing thread mid-close, and
   the descriptor stays open, so the client never sees the close.
   `Connection#close` now shuts the socket down and leaves closing it to
   `Server.serve`'s `ensure`. The end-to-end test is a new
   `live_pg_browser_test.rb`, since `live_multiprocess_browser_test.rb`
   runs on Redis; it fails against the old listener.)
   `websocket_pg_fanout_test.rb` and, end to end, `live_pg_browser_test.rb`:
   - terminate the `LISTEN` backend, then a later broadcast from another
     process still arrives;
   - an open page is closed with `1011`, reconnects and resyncs, so a
     patch published while the listener was down shows up;
   - a malformed notify is logged and skipped, and the next one still
     arrives.
6. **Docs.** (Done.)
   - `docs/guides/persistence.md`: a "When the connection drops" section
     (the probe, no retry, one failed request at most).
   - `docs/guides/live.md` and `docs/design/live-pg-fanout.md`: the
     listener's reconnect and the forced resync.
   - CHANGELOG.

## Open questions

- **Silent drops.** When a network path dies without a `FIN` (a NAT or
  load balancer timing out an idle connection), the socket never becomes
  readable, the probe sees nothing, and the next query waits for TCP to
  give up, which can take minutes. libpq's `keepalives_idle`,
  `keepalives_interval`, `keepalives_count` and `tcp_user_timeout` bound
  this (`connect_timeout` is decided, decision 3). Not tested here.
  Measure, then decide whether `Pg.connect` should set defaults or the
  guide should recommend them.
- **`RedisFanout`** had the same subscriber gap: once subscribed, any
  error re-raised and ended its Ractor. Fixed after phase 6, the same way:
  the subscriber resubscribes with backoff, closes every socket with
  `1011`, and skips a malformed message, which it used to deliver to
  sockets as `nil`. The backoff and the log a subscriber can't die from
  moved to `Listeners`, shared by both fanouts. The publisher needed
  nothing: redis-rb reconnects and resends a failed command once, so a
  publish can arrive twice if the drop comes after Redis received it.
  Turning that resend off would fail the first publish after every idle
  drop, and redis-rb has no way to check a connection without a round
  trip, so it stays.
