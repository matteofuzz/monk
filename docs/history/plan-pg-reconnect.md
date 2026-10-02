# Recovering from a dropped Postgres connection — implementation plan

> **Historical document.** It records how this was planned or built at the time and may describe things that have since changed or shipped. For how Monk works today, see [`docs/guides/`](../guides/).

Status: proposed 2026-10-01, not started. Found while reviewing monk_talk's
connection lifecycle on monkrb 0.19.0.

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
4. **The probe and the reset belong to the backend, not the Registry.**
   `Registry#checkout` calls two new backend hooks: `alive?(conn)` and
   `revive(conn)`. They default to "always alive" and a no-op, so the
   Registry stays backend-agnostic. `Monk::Persistence::Pg` implements
   them as above. `alive?` is public on `Pg` so `PgFanout` reuses it.
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
7. **A `500` logs its exception.** `Base#dispatch` logs
   `Monk::Log.error("#{e.class}: #{e.message}")` with the first backtrace
   lines when no `error` handler matched, and also when one did. The
   request line stays as it is.

## Phases

Small red → green slices, as in the other plans. The tests need a real
Postgres, like `persistence_test.rb` and `websocket_pg_fanout_test.rb`,
and drop connections with `pg_terminate_backend` from a second
connection.

1. **Log the exception behind a `500`.** `error_handling_test.rb`: a
   route that raises logs its class and message, with and without a
   handler.
2. **Backend hooks and the checkout probe.** `persistence_test.rb`:
   - a checkout after `pg_terminate_backend` succeeds, on a new backend
     pid;
   - a block that raises `PG::ConnectionBad` mid-way propagates (no
     retry: a counter in the block is 1), and the next checkout works;
   - the json type map survives a reset;
   - with Postgres unreachable (a registered port nothing listens on, so
     the test doesn't stop the server), checkout raises
     `PG::ConnectionBad` and doesn't hang.
3. **Same in a worker Ractor.** `persistence_ractor_integration_test.rb`:
   terminate a worker Ractor's connection, then the next checkout in that
   Ractor succeeds.
4. **Publisher.** `websocket_pg_fanout_test.rb`: terminate the
   publisher's backend, then `broadcast` reaches another process's
   listener.
5. **Listener.** `websocket_pg_fanout_test.rb` and, end to end,
   `live_multiprocess_browser_test.rb`:
   - terminate the `LISTEN` backend, then a later broadcast from another
     process still arrives;
   - an open page is closed with `1011`, reconnects and resyncs, so a
     patch published while the listener was down shows up.
6. **Docs.**
   - `docs/guides/persistence.md`: a "When the connection drops" section
     (the probe, no retry, one failed request at most).
   - `docs/guides/live.md` and `docs/design/live-pg-fanout.md`: the
     listener's reconnect and the forced resync.
   - CHANGELOG.

## Open questions

- **How the subscriber reaches every socket.** The Registry maps keys to
  ports and knows no connections. One option: a sentinel broadcast to
  every registered port that `Live::Session`'s relay treats as "close
  with 1011". Decide in phase 5.
- **Silent drops.** When a network path dies without a `FIN` (a NAT or
  load balancer timing out an idle connection), the socket never becomes
  readable, the probe sees nothing, and the next query waits for TCP to
  give up, which can take minutes. libpq's `keepalives_idle`,
  `keepalives_interval`, `keepalives_count`, `tcp_user_timeout` and
  `connect_timeout` bound this, and with no `connect_timeout` a reset to
  an unreachable host waits indefinitely. Not tested here. Measure, then
  decide whether `Pg.register` should set defaults or the guide should
  recommend them.
- **`RedisFanout`** probably has the same publisher and subscriber gap.
  Not checked.
- **A transaction left open.** A block that runs a raw `BEGIN` and raises
  leaves the connection in a transaction, and the next checkout in that
  Ractor runs inside it. `conn.transaction` already rolls back, so only
  raw `BEGIN` is exposed. `checkout`'s `ensure` could `ROLLBACK` when
  `transaction_status` isn't idle. Same mechanism, a separate decision.
