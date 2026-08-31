# Persistence & database connections under Ractor isolation

Status: decided, pending the live spike in Phase 0. Resolved via an interview
session on 2026-08-29/31 — see "Resolved design" below. Implementation plan:
`PLAN-PERSISTENCE.md`. Working branch: `main_dev/add_db_support`. No ADR yet;
one should be written once Phase 0's spike confirms the approach holds.

## Resolved design

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
