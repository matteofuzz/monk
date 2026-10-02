# Persistence — `Monk::Persistence::Pg`

Persistence is opt-in: `require "monk"` alone never loads it. Postgres is the
only backend today, via raw `pg` (Sequel was tried first and ruled out — it
raises `Ractor::IsolationError` from any non-main Ractor, with no
workaround; see [`design/persistence-ractor-connections.md`](../design/persistence-ractor-connections.md)). Add `pg` to your
own `Gemfile` and:

```ruby
require "monk/persistence/pg"        # registry + raw connection access
require "monk/persistence/pg/model"  # CRUD sugar on top (needs the above)
```

## Setting up a database

Any reachable Postgres works — a local install or a container:

```
docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:16
```

Create the database and tables yourself, or with [`migrations.md`](migrations.md);
`table_name` is never inferred, so it can be anything:

```
createdb monk_app
psql monk_app -c "CREATE TABLE widgets (id SERIAL PRIMARY KEY, name TEXT NOT NULL, quantity INTEGER NOT NULL DEFAULT 0)"
```

## Connecting

`register` a name once, with the same kwargs `PG.connect` takes, then use
that name everywhere — each Ractor lazily opens and memoizes its own
`PG::Connection` on first access (connections are never shared across
Ractors):

```ruby
Monk::Persistence::Pg.register(:main, host: "127.0.0.1", port: 5432, user: "postgres", password: "postgres", dbname: "monk_app")
```

Do this once at app boot, before `Monk.boot(App)` (in a `monk new` app,
`config/persistence.rb`, which `config/load.rb` requires), not inside a
route.

Connections get `connect_timeout: 5` unless you pass your own, so
connecting to a host that doesn't answer fails after 5 seconds instead of
waiting indefinitely.

**Per-environment database names.** `MONK_ENV` (see [`settings.md`](settings.md)) and
the database name are two separate, unlinked knobs — setting `MONK_ENV=test`
does not change which database you connect to. The `--postgres` scaffold's
`config/persistence.rb` reads a single `DB_NAME` env var with a static
fallback (`app_development`), so naming a database per environment is
entirely by convention/operator action, not framework magic:

- **Locally**: export `DB_NAME` yourself before running tests, e.g. in a
  `.env.test` your test runner loads, or inline: `DB_NAME=myapp_test bin/...`.
- **Deploys** (see [`deploying.md`](deploying.md)): Render/Fly secrets set `DB_NAME`
  explicitly per service/environment — there's a real, separate Postgres
  instance per environment, and its name is whatever you typed into
  `fly secrets set` / Render's env var UI.
- **Monk's own test suite** (testing the `monk` gem itself, not a generated
  app) uses a different variable, `MONK_TEST_PG_DATABASE` (default
  `monk_test`), read in `test/test_helper.rb`. That's internal to this repo
  and isn't inherited by apps `monk new` generates.

## Models

A `Monk::Persistence::Pg::Model` subclass points at a registered `db_name`
and a `table_name`. It's deliberately not an ORM — no associations,
validations, callbacks, or dirty-tracking, and no live row objects: every
method takes or returns plain Symbol-keyed `Hash`es.

```ruby
class Widget < Monk::Persistence::Pg::Model
  self.db_name = :main
  self.table_name = "widgets"
end

Widget.create(name: "bolt", quantity: 10)     # => { id: 1, name: "bolt", quantity: 10 }
Widget.find(1)                                # => { id: 1, name: "bolt", quantity: 10 } or nil
Widget.find_all([1, 2, 99])                   # => [row1, row2, nil] -- one round trip, nil for a miss
Widget.where(name: "bolt")                    # => [{ id: 1, ... }, ...] -- AND only, still no OR
Widget.where(quantity: { gt: 5 })             # => comparison operators: gt/gte/lt/lte/ne
Widget.where(quantity: [5, 10])               # => IN -- matches any value in the Array
Widget.where({}, order: :id, limit: 20)       # => ORDER BY / LIMIT via a trailing options Hash
Widget.create_all([{ name: "bolt", quantity: 1 }, { name: "nut", quantity: 5 }])
                                               # => both rows, one INSERT -- every Hash needs the same columns
Widget.update(1, quantity: 20)                # => updated row, or nil if the id doesn't exist
Widget.delete(1)                              # => true/false, whether a row was actually deleted
```

`Monk.boot(App)` freezes every `Model` subclass's `db_name`/`table_name`
(and the connection registry itself) so they're readable from worker
Ractors — the same boot step that seals routes. This means `register` and
any `Model` classes must exist before `Monk.boot(App)` runs.

## Direct access

For anything `Model` doesn't cover, `checkout` yields the underlying
`PG::Connection` directly, serialized against sibling threads in the same
Ractor (a checkout that can't acquire the connection within
`timeout:` seconds, 5 by default, raises `Monk::PersistenceTimeoutError`):

```ruby
Monk::Persistence::Pg.checkout(:main) do |conn|
  conn.exec_params("SELECT * FROM widgets WHERE quantity > $1", [5])
end
```

Use `conn.transaction { ... }` for a transaction. If a block runs a raw
`BEGIN` and raises before its `COMMIT`, the transaction is rolled back when
the block ends, so the next checkout in that Ractor doesn't run inside it.
A transaction can't span two `checkout` blocks.

`Monk::Persistence::Pg[:main]` returns that Ractor's memoized connection
without the checkout lock, and without the dropped-connection check below
— use it for read-only, single-threaded-per-Ractor access; prefer
`checkout` whenever sibling threads might touch the same connection
concurrently.

## When the connection drops

Postgres restarting, a failover, or an admin's `pg_terminate_backend`
closes every connection. Monk recovers without a restart:

- **Each `checkout` checks its connection first** and reconnects it if
  the server closed it. A healthy connection costs about a microsecond and
  nothing is sent. Most drops happen while a connection sits idle between
  requests, so most cost no failed request at all.
- **A block is never run twice.** If the connection drops in the middle
  of a block, that block raises `PG::ConnectionBad` (a `500`, unless
  you handle it), and the next checkout in that Ractor reconnects. Monk
  can't tell whether a failed block's writes reached the server, so
  retrying it could insert a row twice. At most one request per Ractor
  fails per drop.
- **While Postgres is down,** `checkout` raises `PG::ConnectionBad` at
  once, and each later checkout tries to reconnect again. Requests fail
  fast; nothing queues.

What this can't see: a network path that dies without closing the socket
(a NAT or load balancer timing out an idle connection). The socket looks
healthy, and the next query waits until TCP gives up, which can take
minutes. libpq's `keepalives_idle`, `keepalives_interval`,
`keepalives_count` and `tcp_user_timeout` options, passed to `register`,
bound that wait.

`Monk::Jobs` and `Monk::WebSocket::PgFanout` recover in the same way; see
[`jobs.md`](jobs.md) and [`live.md`](live.md).

## Pools

Each Ractor that queries opens a connection of its own on its first
`checkout` and keeps it while it lives. That suits Ractors that live long
and query often: kino's workers, `Monk::Jobs`'s workers. It doesn't suit
many short-lived or mostly idle Ractors, like the WebSocket server's one
Ractor per open socket: a socket that checked its session once holds a
connection for as long as the page stays open. At Postgres's default
`max_connections` (100), an app runs out at around 75 open pages.

A pool runs the work where the connections are instead. A connection
can't be moved or shared between Ractors, so a pool lends nothing: a few
worker Ractors each own one, and other Ractors send them calls.

```ruby
# config/persistence.rb (every process loads it)
Monk::Persistence::Pg.register(:primary, host: ..., dbname: ...)
Monk::Persistence::Pg.pool(:auth, size: 4)

# at boot, only in the process that uses it, after the config is loaded
Monk::Persistence::Pg.start_pools!(:auth)

# anywhere, from any Ractor
Monk::Persistence::Pg.pool(:auth).call(Contacts, :include?, owner, email)
```

- **Declaring** (`pool(name, ...)` with options) connects nothing.
  `start_pools!` starts the pool's workers and returns once each has
  connected; it raises `Monk::PoolStartError` if they can't. It runs in the
  main Ractor and freezes the registry, so `register` and every pool
  declaration come before it. Processes that never start a pool hold no
  pool connections. `pool(name)` with no options looks a started pool up;
  the handle it returns is frozen, so it can be kept in a constant.
- **A call names a method; it carries no block.** The pool's worker runs
  `Contacts.include?(owner, email)`, and the method's own `checkout` gets
  the worker's connection, so models don't change. Everything after the
  method name goes to the method; `call` takes no options of its own.
- **Arguments and return values are copied** between Ractors, so they must
  be data: strings, numbers, arrays, hashes, frozen `Data`. A method that
  returns a `PG::Result` raises `Monk::PoolReturnError`: return rows.
- **Errors keep their class.** `rescue PG::UniqueViolation` works the same
  as in a direct call. What a pool error loses is `e.connection` (it's
  `nil`) and a real `e.result`: it answers `error_field`, `error_message`,
  `result_status` and `res_status`, nothing else. The backtrace shows the
  worker's frames, then `(in pool :auth; called from)`, then yours.
- **Nothing of the caller's travels with the call**: not its Ractor-local
  state, not its open transaction. A call runs on another connection, so it
  can't see rows your own uncommitted transaction wrote.
- **A timeout undoes nothing.** `call` raises `Monk::PersistenceTimeoutError`
  once the pool's `timeout` passes. A call still queued then is dropped and
  never runs; one already running finishes, writes included.
- **Order only at size 1.** A pool larger than 1 runs calls side by side.
  `call_async` returns as soon as the pool has the call, doesn't wait for
  it, never times out, and logs a failure since nobody is waiting; only a
  pool of size 1 runs one sender's async calls in the order it made them.
- **A method that calls its own pool runs inline**, on the worker's
  connection, instead of queueing on a pool it occupies.
- **Workers are replaced.** A worker that dies (not an exception from the
  method, which reaches the caller, but a bug or an `Exception` from deep
  in a C extension) is logged and replaced, and its caller gets
  `Monk::PoolWorkerDiedError`: the call may or may not have finished. A
  replacement that can't connect retries with backoff while calls wait in
  the queue. Workers recover from a dropped connection like any `checkout`
  (above).

| Option | Default | Meaning |
|---|---|---|
| `db:` | `:primary` | The registered database the workers connect to |
| `size:` | 4 | Worker Ractors, so connections |
| `timeout:` | 5 | Seconds a `call` waits, queued and running, before it raises |
| `queue:` | 1000 | Calls that may wait for a worker; beyond it `call` and `call_async` raise `Monk::PoolFullError` at once. A full queue usually means a stalled database |

`Monk.boot` lists the pools running in its process (` - pools=auth(4)`).
Where Monk uses pools itself: `Monk::WebSocket::Server.new(db_pool:)`
([`websocket.md`](websocket.md)), `Monk::Live.authorize(..., db_pool:)` and
`PgFanout.new(..., db_pool:)` ([`live.md`](live.md)).
