# Persistence & database connections under Ractor isolation

Status: Phase 0 spike ran on 2026-08-31 — **Sequel is not usable inside a
non-main Ractor, confirmed empirically**. The "Resolved design" below is
kept as the record of *why* Sequel was chosen and what it bought, but it no
longer describes the plan going forward; see "Phase 0 result" for the
finding and its consequences. Implementation plan: `PLAN-PERSISTENCE.md`.
Working branch: `main_dev/add_db_support`. No ADR yet.

## Phase 0 result (2026-08-31)

Ran against a disposable `postgres:16` Docker container, Ruby 4.0.6,
`pg` 1.6.3, `sequel` 5.107.0. Script and raw output are not committed
(throwaway, per the plan); summarized here.

**Sequel: fails outright, every configuration tried.** `Sequel.connect`
called from *any* non-main Ractor — first call, second call, two Ractors
spawned concurrently, and even after the main Ractor pre-loads the
postgres adapter (`Sequel::Database.load_adapter(:postgres)`) before
spawning any workers — raises the same error every time:

```
Ractor::IsolationError: can not access non-shareable objects in constant
Sequel::ADAPTER_MAP by non-main ractor.
```

This is stronger than the risk flagged during research: `ADAPTER_MAP` is
*read* on every `connect` call (to look up the already-loaded adapter
class), not just written once on first load, so pre-warming it in the main
Ractor doesn't help — every subsequent read from a worker Ractor still
hits the same isolation error. There is no configuration-level workaround;
this is Sequel's own adapter-loading architecture, unrelated to anything
Monk controls.

**Raw `pg`: works cleanly.** Two separate Ractors, each calling
`PG.connect(...)` and running a real round-trip query
(`SELECT 1`) against the container, both succeed with no Ractor errors —
consistent with `pg`'s own documented "fresh connection per Ractor"
pattern from the earlier research pass.

**Consequence — this reopens Q1 and Q4, not just Q2's engine pick.** The
whole point of choosing Sequel (Q1: "no separate adapter interface, Sequel
*is* the agnostic layer") and `DatasetProxy` (Q4: delegates to Sequel
dataset methods like `.where`/`.all` via `method_missing`) assumed a query
layer that no longer applies. Raw `pg` has no dataset/query-builder
abstraction — only `exec`/`exec_params` returning a `PG::Result` — and is
Postgres-specific, so "agnostic" can no longer mean "delegate to Sequel's
own multi-adapter system"; if agnosticism is still wanted, Monk itself
would now have to own that abstraction (the option Q1 explicitly declined).
This needs a decision, not a silent substitution — see the message
accompanying this update for the actual question.

## Phase 0 follow-up: `Monk::Persistence::Model` (2026-08-31)

Resolution to the Q1/Q4 reopening above: Monk owns a small, deliberately
non-ORM abstraction itself — CRUD sugar over parameterized SQL, not a
Sequel/AR replacement. No associations, no validations, no callbacks, no
dirty-tracking; same "small primitive, not a framework" instinct as
`StateRactor`.

```ruby
module Monk
  module Persistence
    class Model
      class << self
        attr_accessor :db_name, :table_name

        def create(data)
          cols, vals = data.keys, data.values
          placeholders = vals.each_index.map { |i| "$#{i + 1}" }
          sql = "INSERT INTO #{table_name} (#{cols.join(",")}) VALUES (#{placeholders.join(",")}) RETURNING *"
          connection.exec_params(sql, vals).first
        end

        def find(id)
          connection.exec_params("SELECT * FROM #{table_name} WHERE id = $1", [id]).first
        end

        def where(conditions)
          clause = conditions.keys.each_with_index.map { |c, i| "#{c} = $#{i + 1}" }.join(" AND ")
          connection.exec_params("SELECT * FROM #{table_name} WHERE #{clause}", conditions.values).to_a
        end

        def update(id, data)
          sets = data.keys.each_with_index.map { |c, i| "#{c} = $#{i + 2}" }.join(", ")
          connection.exec_params("UPDATE #{table_name} SET #{sets} WHERE id = $1 RETURNING *", [id, *data.values]).first
        end

        def delete(id)
          connection.exec_params("DELETE FROM #{table_name} WHERE id = $1", [id])
        end

        private def connection = Monk::Persistence[db_name]
      end
    end
  end
end
```

Four decisions locked in alongside this:

1. **Hash-only, no live model instances.** Every method takes/returns plain
   `Hash`es, never an `Event` *instance* wrapping a row. A live mutable
   row-object can't cross a Ractor boundary cleanly — the same reason the
   original RPC-pool design (superseded, below) couldn't return live AR
   objects, and the same reason `DatasetProxy` had to be a frozen handle
   rather than the live dataset itself. Plain Hashes copy across Ractor
   boundaries automatically; there's nothing to make shareable.
2. **`Model` subclasses hook into `.freeze!`, the same way routes do.**
   `Event.db_name = :analytics` writes a class-instance-variable in the
   main Ractor at load time; reading it later from a worker Ractor is the
   same category of access `.freeze!` already exists to make safe for
   routes (`Ractor.make_shareable(routes)` before any worker touches them).
   `Model` subclasses get tracked via an `inherited` hook (mirrors how
   `Base` tracks routes), and `.freeze!` calls `Ractor.make_shareable` on
   each one's config, raising a precise error naming the offending class
   if something isn't shareable — extends Seam B, doesn't invent a new
   pattern.
3. **A per-Ractor `Mutex` replaces Sequel's connection pool.** Sequel's
   `ConnectionPool` safely queued concurrent checkouts under `:threaded`
   mode; a bare `PG::Connection` isn't safe for two threads to issue
   commands on concurrently (wire-protocol corruption, not a graceful
   wait). The per-Ractor connection is wrapped in a `Mutex`-guarded
   checkout with a timeout; a checkout that can't acquire the lock in time
   raises `Monk::PersistenceTimeoutError` — this replaces catching
   `Sequel::PoolTimeout` from the original plan, but preserves the same
   Q3b guarantee (fail loud under contention, don't corrupt).
4. **`where` supports only equality + `AND`, for now.** Anything past that
   (`>`, `IN`, `LIKE`, `OR`) is a query-condition DSL — real scope growth,
   left out until something actually needs it.

Not yet decided/built: table-name inference (currently explicit-only, no
pluralization magic) and `PG::Result`'s string-typed values need
`conn.type_map_for_results = PG::BasicTypeMapForResults.new(conn)` set up
per connection so `Hash` values come back as proper Ruby types rather than
all-Strings — both are implementation details for `PLAN-PERSISTENCE.md`,
not open design questions.

## Phase 4 finding: freezing a Class does nothing for its ivars (2026-08-31)

Resolves the "does `Ractor.make_shareable` on a Class actually protect its
instance variables" question this document left open all the way back in
its first analysis pass. Verified empirically (see `PLAN-PERSISTENCE.md`
Phase 4): **no.** `Ractor.shareable?(SomeClass)` is unconditionally `true`
regardless of what's in its instance variables — Class/Module objects are
always reported shareable. Calling `Ractor.make_shareable(SomeClass)`
doesn't touch its ivars at all: an ivar holding a plain, unfrozen value
(e.g. `table_name = "widgets"`, a String literal) still raises
`Ractor::IsolationError: can not get unshareable values from instance
variables of classes/modules from non-main Ractors` when read from a
worker Ractor — identically whether or not `make_shareable` was ever
called on the class.

What actually works: freezing the **value** stored in the ivar, not the
class holding it (`subclass.table_name = Ractor.make_shareable(subclass.
table_name)`). Once the stored value is itself shareable, reading the
class-level ivar from any Ractor succeeds — the restriction is on
unshareable *values*, not on cross-Ractor class-ivar reads in general
(confirmed separately: a `db_name` set to a Symbol, which is inherently
frozen/shareable, reads fine cross-Ractor with zero action needed — only
String-valued config like `table_name` was ever at risk).

This is a real, live bug in the `Model` classes shipped in Phases 2–3
(`table_name` set via plain String literals, e.g. `self.table_name =
"widgets"`) — every `Model` subclass would have failed the moment a real
worker Ractor tried to read `table_name`, silently past `.freeze!` (which,
before Phase 4, validated routes/handlers but nothing about `Model`
subclasses at all). Phase 4 is what closes this gap.

**Decided against** (Phase 4's plan step 14, "decide test-first"): validating
that every `Model`'s `db_name` is actually `register`'d in
`Monk::Persistence` at boot time. `Model.subclasses` is necessarily a
process-global registry (`Model` classes are standalone, not owned by any
particular `Base` subclass, so there's no language-level way to scope the
registry per-app) — adding a "must be registered" check surfaced exactly
the failure mode this reasoning predicts: in the test suite, one file's
transiently-registered `Persistence` config being absent during another
file's `.freeze!` call produced false failures unrelated to the app
actually booting. The shareability check doesn't have this problem (it's
a pure property of the class, independent of any registry's current
state), so it's kept; the registration check is dropped.

## Phase 5 finding: the same bug, one level up — `Monk::Persistence` itself (2026-08-31)

Phase 4's finding turned out to be incomplete: it fixed `Model` subclasses'
own `db_name`/`table_name`, but `Monk::Persistence`'s connect-options
registry (`@configs`) has the identical problem, one layer below —
`Monk::Persistence` is itself a Module (always shareable regardless of its
ivars, per the Phase 4 finding), and `@configs` is a plain, unfrozen
`Hash`. Verified empirically before writing Phase 5's tests: with only
Phase 1–4 code in place, `Monk::Persistence[:some_db]` called from inside
a real, separately-spawned `Ractor.new` raised `Ractor::IsolationError:
can not get unshareable values from instance variables of classes/modules
from non-main Ractors (@configs from Monk::Persistence)` — meaning **every
`Model` method, and `Monk::Persistence[]`/`.checkout` directly, was
completely unusable from any real worker Ractor**, despite all of Phases
1–4's tests passing, because none of them had ever run outside the main
Ractor. This is exactly the failure mode Seam G (`PLAN-PERSISTENCE.md`)
exists to catch — "the only place that proves the premise holds under real
parallelism" — and it caught it on the first real spike.

Fix: the same one as Phase 4, one level up. `Monk::Persistence.
freeze_registry!` freezes the `@configs` Hash itself (`Ractor.
make_shareable(configs)`) — called from `Base#freeze!` alongside `Model.
freeze_all!`. Once the registry value is frozen, `Monk::Persistence.
register` calls after boot correctly raise `FrozenError` (the same
precedent `routes` already sets: nothing can be registered after
`.freeze!`, by design), and reads from any Ractor succeed.

Confirmed working end-to-end: real `Ractor.new` calls doing concurrent
`Model.find`/`.create` against a live Postgres container, and two real
threads inside one spawned Ractor contending for that Ractor's own
connection slot (proving `Monk::PersistenceTimeoutError` fires under real
contention, not just a simulated one in the main Ractor) — see
`PLAN-PERSISTENCE.md` Phase 5.

## Resolved design (superseded — see "Phase 0 result" and "Phase 0 follow-up," above)

**Scope & positioning**
- First-class Monk primitive (`Monk::Persistence`), not just a documented
  pattern — same tier as `StateRactor`.
- Sequel is the engine-agnostic layer itself; Monk adds no separate adapter
  interface on top of it (see "Framing correction" below for what that
  ruled out).
- Postgres (`pg`) as the first/only engine for now. SQLite is ruled out —
  `sqlite3-ruby` raises `Ractor::UnsafeError` outright inside a non-main
  Ractor (open issue since 2021, unresolved). ActiveRecord is ruled out —
  Rails core itself currently funnels all Ractor DB queries back to the
  main Ractor as a stopgap (per a 2026-08-11 Rails-core post), so there is
  no known-good upstream pattern to build on yet.
- Multi-database support from the start.
- Treated as exploratory: ready to change approach if the live Sequel-in-
  Ractor test (Phase 0) doesn't hold up.

**Architecture**
- Connections are never shared across Ractors — each worker Ractor lazily
  creates and owns its own, on first use. No dependency on Kino's
  `after_worker_boot` (confirmed real and exposed, per fact-finding below)
  even though it exists — staying Kino-agnostic per ADR 0001.
- Every `Sequel.connect` call passes `keep_reference: false`, so it never
  touches Sequel's process-wide `DATABASES` registry.
- `max_connections: 1` per Ractor by default — matches Kino's default of
  one thread per worker in `:ractor` mode. `Sequel::PoolTimeout` is caught
  and re-raised as a Monk-specific error naming the pool, so an undersized
  pool under `:threaded` mode (3 threads/worker by Kino's default) fails
  loud with an actionable message instead of a generic timeout.

**API surface**
- `Monk::Persistence.register(name, **sequel_opts)` — declared at
  app-definition time, like routes.
- `Monk::Persistence[name]` — direct registry lookup; resolves/caches the
  connection for the calling Ractor.
- `Monk::Persistence.dataset(db_name, table_name)` → a frozen
  `DatasetProxy` (holds only two Symbols, trivially `Ractor.shareable?`) —
  the primary ergonomic pattern. Bind once at load time
  (`Events = Monk::Persistence.dataset(:analytics, :events)`), use plainly
  in routes; each method call re-resolves through the per-Ractor cache
  underneath via `method_missing`.
- A `db(name = :primary)` `Context` helper as a third option, for
  request-time DB selection (e.g. sharding/tenant routing), where the
  target database can't be fixed at load time.

**Framing correction that shaped the API surface**: an "immutable
connection passed to worker Ractors" isn't achievable as literally stated —
`Ractor.make_shareable` requires deep-freezing, and a connection can't be
frozen and remain usable (issuing a query mutates its buffers/transaction
state). The achievable version is `StateRactor`'s own trick: the mutable
thing stays mutable but lives invisibly per-Ractor; what crosses Ractor
boundaries is a frozen *handle* (in this case, `DatasetProxy`, or the
registry's name-keyed lookup), never the live connection itself. The same
reasoning ruled out a literal Shape-3 constant binding
(`Events = Monk::Persistence[:analytics][:events]` evaluated once, at
load time, in the main Ractor) — Ruby raises `Ractor::IsolationError` when
a non-main Ractor reads a constant whose value isn't shareable and wasn't
assigned from that Ractor, so a naive version would fail per-worker, at
first request, well past `.freeze!` — exactly the silent-failure mode
ADR 0003 exists to prevent. `DatasetProxy` is the fix: the object bound to
the constant is shareable, and the actual resolution is deferred to each
call, inside whichever Ractor makes it.

**Two things ruled out along the way, and why**
- A single `StateRactor` wrapping one shared connection: would serialize
  all DB I/O across the entire worker pool behind one mailbox, defeating
  the reason to use Ractors for concurrency at all.
- Ownership transfer via `Ractor.send(obj, move: true)`: pg's own docs say
  `PG::Connection` must be created fresh per Ractor, with no mention of
  move support — treated as unverified and not load-bearing for the design.

## Facts gathered during the interview (2026-08-29/31)

- **Local env**: Ruby 4.0.6 (arm64-darwin25, +PRISM). No `pg`/`sqlite3`/
  `sequel`/`activerecord` installed locally as of the research pass.
- **`pg`**: Ractor support landed in 1.5.0. `PG::Connection` is explicitly
  documented as not shareable and must be created fresh per Ractor — this
  directly validated the per-worker-owned-connection architecture over the
  originally-drafted RPC/dedicated-connection-Ractor-pool alternative
  (see "Two things ruled out," above, and the superseded draft further
  down this document).
- **`sqlite3-ruby`**: constructing a DB inside a non-main Ractor raises
  `Ractor::UnsafeError`. Open issue since 2021, unresolved, targeted at an
  unshipped 2.0.0.
- **ActiveRecord/Rails**: a Rails-core post dated 2026-08-11 states the
  team is currently funneling all DB queries back to the main Ractor as a
  stopgap while they figure out per-Ractor connection management.
- **Sequel**: `Sequel::DATABASES` is a real, plain, process-wide array
  every `Database` registers into by default (`lib/sequel/database/misc.rb`,
  ~line 103/120) — mitigated via `keep_reference: false`, which is already
  a supported `Sequel.connect` option, not something Monk needs to invent.
  `ADAPTER_MAP`/`SHARED_ADAPTER_MAP` are module-level hashes caching loaded
  adapter classes by scheme, populated lazily on first `require` of an
  adapter, with **no equivalent opt-out** — this is the open, unmitigated
  risk and the reason Phase 0 of the implementation plan is a live test
  (`Ractor.new { Sequel.connect(...) }` from two separate Ractors) rather
  than an assumption.
- **Kino (0.4.0)**: worker pool is fixed-size, not dynamically scaled —
  defaults to CPU core count (`Kino.available_parallelism`), configurable
  via `workers N`. It exposes a real `after_worker_boot(&block)` hook,
  running once inside each worker Ractor before it serves any request —
  confirmed but deliberately not depended on, per ADR 0001. `:ractor` mode
  runs 1 thread per worker by default; `:threaded` mode runs 3.
- **`monk-consumer-test`** (sibling repo, not part of Monk's own git
  history): already exists, already consumes Monk via
  `gem "monk", path: "../monk"`, and already matches what `main` provides —
  `monk.gemspec` and `lib/monk/version.rb` (`VERSION = "0.1.0"`) landed via
  the already-merged `package-monk-as-local-gem` branch (PR #20). No gem-
  packaging prep work remains; this app is the Phase-6/Seam-H validation
  target in the implementation plan.
- **Local Postgres**: not running (`pg_isready` unreachable,
  `postgresql@14` installed via brew but stopped). Docker is available and
  idle. Decision: use a disposable `docker run postgres` container for the
  live spike rather than starting the brew service.

## Current state (superseded by "Resolved design," kept for rationale)

There is no persistence layer in Monk today. `README.md` lists persistence as
deliberately out of scope for v1. `NOTES-V2.md` lists "Database support,
Postgres first" as a v2 candidate with no design attached. This document is
the first pass at that design space: how to support existing Ruby DB gems
without weakening Monk's core guarantee — that a booted app is
`Ractor.shareable?` and safely dispatchable across a Ractor worker pool.

## The core tension

Monk's model (see ADRs 0001–0003): after `.freeze!`, the app's routes,
`Context`, and helpers are sealed into a `Ractor.shareable?` structure. The
only sanctioned way to hold cross-request mutable state is `StateRactor` — a
dedicated Ractor wrapping a value, accessed via serialized message-passing.
Database connections break this model in several ways:

1. **Connections can't be shared, only encapsulated.** A `PG::Connection`,
   `Sequel::Database`, or AR connection wraps a live socket, buffers, and
   transaction state — inherently mutable, un-freezable. It can never be a
   local a route block closes over; that's the same `UnshareableRouteError`
   the README shows for a mutable counter, just with a connection instead.
2. **A single `StateRactor` is the wrong shape for it.** Wrapping one
   connection in a `StateRactor` would route every query through one
   mailbox, one message at a time — serializing all DB I/O across the whole
   worker pool and defeating the reason to use Ractors for concurrency at
   all.
3. **C-extension Ractor-safety is a separate, external gate.** Gems like
   `pg`, `mysql2`, `sqlite3` are C extensions. Beyond shareability of the
   object graph, the extension itself must be flagged Ractor-safe
   (`rb_ext_ractor_safe`) by its maintainers to be usable inside a non-main
   Ractor at all. Whether/how far each gem has done this on the Ruby version
   this project targets (4.0+) is not something to assume from memory — it
   needs an empirical spike.
4. **ActiveRecord's model fights Ractor isolation structurally**, independent
   of the C driver question. AR's connection handling relies on class-level
   mutable state shared across the whole process (`connection_handler`, pool
   registries, query cache, type maps) under a single-GVL, single-address-space
   assumption that Ractors don't provide.

## What fits Monk's existing model

The pattern consistent with the rest of the codebase: never share a live
connection across Ractors; give each unit of DB access its own, owned inside
a dedicated Ractor, never captured as a closed-over local in a route block.
This is `StateRactor`'s own trick, generalized.

### Framing correction: "immutable connection" isn't the right target

`Ractor.make_shareable` requires deep-freezing. A connection can't be frozen
and remain usable — issuing a query mutates internal state (buffers,
transaction status). So "pass an immutable connection to worker Ractors" is
not achievable as literally stated. What *is* achievable, mirroring
`StateRactor`: the connection stays mutable but lives invisibly inside a
dedicated Ractor, and what gets passed to workers is a frozen **handle** to
that Ractor — always `Ractor.shareable?` regardless of what mutates inside
it.

### Proposed shape: a pool of connection-owning Ractors ("StateRactor × N")

**Superseded**: this was the leading candidate before `pg`'s own Ractor
docs were checked (see "Facts gathered," above). `pg` documents the
opposite pattern as correct — a fresh `PG::Connection` per Ractor, never
shared — which is simpler than the RPC-shaped design below and needs none
of its machinery. Kept here for the reasoning trail, not as the plan.

A fixed set of N dedicated Ractors, each privately holding one live
connection, exposed to worker Ractors as a frozen array of Ractor handles
(or a single dispatcher Ractor). Concretely this would be built at
`.freeze!` time — the same lifecycle moment that already seals routes —
rather than requiring a hook into whatever worker-lifecycle mechanism the
host server (Kino or otherwise) uses, which Monk doesn't control (ADR 0001,
Kino-agnostic).

Why this resolves the earlier objections:

- **Throughput**: pool size is a normal tunable (like AR's `pool: 5`),
  not a structural single-mailbox bottleneck.
- **Audit surface**: the DB C extension only needs to behave correctly
  inside a small, fixed number of Ractors Monk itself creates — not inside
  every worker Ractor the host server dynamically spins up.
- **Boot ordering**: Monk creates the pool itself at `.freeze!`; workers
  never need to create anything, they just receive a handle, same as they
  already receive the route table.

### The real cost: an RPC-shaped query boundary

Once a connection is trapped inside another Ractor, a worker can't call
`conn.exec(sql)` directly — it can only send a message and receive a reply.
Plain values (strings, arrays, hashes, numbers) cross the boundary via
Ruby's automatic copy semantics; live, mutable object graphs (an AR model
instance with dirty-tracking, lazy associations, callbacks) do not survive
the crossing and can't be handed back.

Reconciling move: the gem itself still runs **natively inside the
connection-Ractor** — that Ractor can hold a real `Sequel::Database` or AR
connection and use it idiomatically. Only the boundary has to speak plain
data: the worker sends something like `(sql, params)` or `(:find_user, id)`,
the connection-Ractor executes the real gem call internally, and replies
with a plain hash/array. "Support existing gems" survives, one layer removed
from a route block calling `User.find(1)` directly — behind a small
message-passing API Monk would own.

**Transaction/session affinity**: `BEGIN; INSERT; COMMIT` must all land on
the *same* pool member, not get round-robined per statement. The protocol
needs a "checkout this connection-Ractor for the duration of one
request/transaction" step, not independent fire-and-forget messages per
statement. Solvable (every connection pool handles this) but adds protocol
complexity beyond simple request/reply.

### Variant B (unverified, not load-bearing): ownership transfer via `move:`

`Ractor.send(obj, move: true)` can transfer ownership of a non-shareable
object rather than copy it — the sender's reference becomes inaccessible
afterward. In theory, a pool-manager Ractor could `move` a live connection
out to whichever worker needs it; the worker then uses it with fully
idiomatic, zero-overhead native gem calls (it's just a normal object in that
Ractor now), and moves it back when done. No RPC shim, no plain-data
translation.

This depends on the C extension explicitly supporting Ractor's move
protocol for its wrapped native object (e.g. `PG::Connection`'s underlying
`PGconn*`). Built-in types (Array/Hash/String) support this; whether
`pg`/`sqlite3` do on the target Ruby version is unknown and should not be
assumed. If it doesn't work cleanly, this collapses back to the RPC-shaped
pool design above, which doesn't depend on `move` at all. Treat as a
possible later optimization, not a design dependency.

## Three shapes for the gem layer itself

| Approach | Ractor risk | Gem ecosystem |
|---|---|---|
| Raw driver (`pg`/`sqlite3`) behind a per-Ractor lazy accessor | Lowest — smallest surface to audit | Hand-written SQL, no ORM ergonomics |
| Sequel, one connection per pool member, pool never shared globally | Medium — pluggable pool, less globally-stateful core | Full adapter/migration/dataset ecosystem |
| ActiveRecord | Highest — deep class-level global state not designed against Ractor isolation | Best familiarity, but the likeliest path to silently reintroducing the exact failure ADR 0003 exists to prevent |

## Open questions requiring empirical verification (not assumption)

1. Does `pg` (or `sqlite3`, as a lighter local-dev default) work at all
   inside a non-main Ractor on the Ruby 4.0 this project targets?
2. Do those gems' connection objects support Ractor's `move:` protocol, or
   does attempting to move one error out / produce unsafe duplicate native
   state?
3. What does AR's or Sequel's pool implementation assume about
   thread/fiber-locality that might not translate to Ractor-locality?
4. How should a checked-out connection be reclaimed if the worker Ractor
   holding a lease dies mid-request (crash/timeout recovery for the pool)?

## Recommendation

Spike question 1 first — it gates every other option. If the underlying
driver can't run inside a non-main Ractor at all, no Monk-side design routes
around it, and the honest fallback is documenting that persistence forces
`--mode threaded` until upstream Ractor support lands (mirroring the
existing `bin/server --mode threaded` fallback for other gaps).
