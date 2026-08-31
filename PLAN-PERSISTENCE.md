# Monk persistence — implementation plan

Branch: `main_dev/add_db_support`. Companion doc:
`docs/persistence-ractor-connections.md` (design rationale, facts gathered,
resolved decisions).

**Phase 0 ran on 2026-08-31 and failed for Sequel**: `Sequel.connect` from
any non-main Ractor raises `Ractor::IsolationError` on `Sequel::ADAPTER_MAP`,
with no workaround found (pre-loading the adapter in the main Ractor first
doesn't help — the map is read on every connect, not just written once).
Raw `pg` was tested as the pivot target and works cleanly across Ractors.
**Phases 1+ below reflect the pivot**: raw `pg` in place of Sequel, and
`Monk::Persistence::Model` (Hash-in/Hash-out CRUD sugar Monk owns itself)
in place of `DatasetProxy` — see the companion doc's "Phase 0 follow-up"
section for the design and the four decisions behind it. This revision
supersedes the original Sequel-based phases; nothing below should be
implemented against the pre-spike version.

Like `PLAN.md`, this develops in small, gradual, red → green cycles. Each
numbered step is one vertical slice: one failing test against its seam,
then the minimum code to pass it. Phase 0 is the exception — it's a spike,
not TDD, and it gated everything after it.

## Seams

- **Seam E — `Monk::Persistence`'s own public API**: registry and
  per-Ractor connection lifecycle (a `Mutex`-guarded raw `PG::Connection`,
  not a pool), tested directly against its own interface (mirrors how
  `PLAN.md` Seam C tested `StateRactor`).
- **Seam F — `Monk::Persistence::Model`**: the CRUD-sugar layer
  (`create`/`find`/`where`/`update`/`delete`) built on top of Seam E.
- **Seam B (extended) — `.freeze!` / boot**: `Model` subclasses need their
  class-level config (`db_name`, `table_name`) made `Ractor.shareable?` at
  boot, the same way routes already are.
- **Seam G — real concurrent Ractor integration**: multiple real Ractors
  actually hitting a live Postgres through Seam E/F at once — the
  persistence equivalent of `PLAN.md` Seam D, and the only place that
  proves the premise holds under real parallelism.
- **Seam H — `monk-consumer-test` end-to-end**: the gem consumed from
  *outside* the repo, via the `path:` dependency, boots for real and
  serves a request that round-trips to Postgres.

## Phase 0 — Spike: does Sequel survive across Ractors? (gated everything below)

Not TDD — a throwaway experiment, already run. Result: **failed, no
workaround, pivot triggered.** Sequel raises `Ractor::IsolationError: can
not access non-shareable objects in constant Sequel::ADAPTER_MAP by
non-main ractor.` from any non-main Ractor, in every configuration tried
(first call, second call, concurrent calls, and pre-loading the adapter in
the main Ractor first). Raw `pg` was verified as the fallback: two separate
Ractors, each calling `PG.connect(...)` and running a real round-trip
query, both succeeded with no Ractor errors. Full detail:
`docs/persistence-ractor-connections.md` → "Phase 0 result."

## Phase 1 — Registry & per-Ractor connection lifecycle (Seam E)

1. `Monk::Persistence.register(:name, **pg_opts)` stores the config for
   later lookup (`pg_opts` are plain `PG.connect` kwargs: `host`, `port`,
   `user`, `password`, `dbname`, ...).
2. `Monk::Persistence[:name]` raises a precise error (naming the missing
   key) for an unregistered name — fail fast, per ADR 0003's spirit.
3. `Monk::Persistence[:name]` lazily creates a `PG::Connection` on first
   call within a Ractor, and memoizes it — a second call from the *same*
   Ractor returns the identical object (test via `equal?`). Sets
   `conn.type_map_for_results = PG::BasicTypeMapForResults.new(conn)` at
   creation time, so results come back as proper Ruby types rather than
   all-Strings.
4. Every checkout of that connection goes through a `Mutex`-guarded
   accessor (internal to `Monk::Persistence`, used by `Model` — not part of
   the public API), serializing concurrent access from sibling threads
   within the same Ractor. A checkout that can't acquire the lock within a
   timeout raises `Monk::PersistenceTimeoutError`, naming the pool/database
   key.

## Phase 2 — `Monk::Persistence::Model`: create/find (Seam F, part 1)

5. A `Model` subclass declares `db_name`/`table_name` via class-level
   accessors (e.g. `class Event < Monk::Persistence::Model; self.db_name =
   :analytics; self.table_name = "events"; end`).
6. `Model.create(data)` inserts a row via a parameterized `INSERT ...
   RETURNING *` and returns the created row as a `Hash`.
7. `Model.find(id)` returns a `Hash` for the row, or `nil` if not found.
8. `Model.create`/`.find` go through the `Mutex`-guarded checkout from
   Phase 1 — verify with a test simulating two threads in one Ractor
   calling in concurrently, confirming no wire-protocol corruption and a
   cleanly serialized result.

## Phase 3 — `Monk::Persistence::Model`: where/update/delete (Seam F, part 2)

9. `Model.where(conditions)` supports only equality + `AND`
   (`where(user_id: 3, active: true)`); returns an `Array` of `Hash`es
   (empty if none match). Explicitly out of scope: any other operator
   (`>`, `IN`, `LIKE`, `OR`) — a query-condition DSL is real scope growth,
   left out until something needs it.
10. `Model.update(id, data)` returns the updated row as a `Hash`, or `nil`
    if `id` doesn't exist.
11. `Model.delete(id)` returns whether a row was actually deleted (not just
    "the DELETE statement ran").

## Phase 4 — Boot integration (Seam B extended)

12. `Model` subclasses are tracked via an `inherited` hook (mirrors how
    `Base` tracks routes) into a class-level registry.
13. `.freeze!` walks that registry and calls `Ractor.make_shareable` on
    each `Model` subclass's config (`db_name`, `table_name`), raising a
    precise error naming the offending class if something isn't
    shareable — same fail-fast pattern `.freeze!` already applies to
    routes.
14. Decide (test-first) whether `.freeze!` should also validate that every
    `Model`'s `db_name` was actually `register`'d in `Monk::Persistence` —
    catching a typo'd `:analytics` vs `:analitics` at boot instead of at
    first request. If yes: `.freeze!` raises a precise error naming the
    unregistered key.

## Phase 5 — Real Ractor integration against live Postgres (Seam G)

15. Multiple real Ractors calling `Model.find`/`.where` concurrently,
    against the live (Dockerized) Postgres from Phase 0, all succeed with
    correct, independent results — the actual proof this design exists
    for. Mirrors `PLAN.md` step 19.
16. Multiple real Ractors calling `Model.create` with distinct data
    concurrently never lose or corrupt a write — mirrors `PLAN.md` step
    20's race-safety proof, but for connections instead of `StateRactor`.
17. Two real threads inside the *same* Ractor both calling into a `Model`
    method concurrently against the `Mutex`-guarded connection — confirm
    serialized correctness (no corrupted results), and force the timeout
    path (e.g. an artificially slow query holding the lock) to confirm
    `Monk::PersistenceTimeoutError` actually triggers under real
    contention, not just against a mocked failure.

## Phase 6 — `monk-consumer-test` end-to-end proof (Seam H)

18. Add a route to `monk-consumer-test`'s `config.ru` defining a `Model`
    subclass and using `.create`/`.find` against the Dockerized Postgres.
19. Boot it for real via `bundle exec rackup config.ru` (or under Kino, if
    `monk-consumer-test` is extended to depend on it) and hit it with
    `curl`, confirming the response reflects real data round-tripped
    through Postgres. Manual smoke test, not CI — mirrors `PLAN.md` step
    21's treatment of Kino verification.

## Explicitly out of scope for this plan

Carried over from the design doc's own scope cuts, plus what the Phase 0
pivot ruled out directly: no ActiveRecord support, no SQLite support
(blocked upstream), no Sequel (blocked upstream, confirmed by Phase 0), no
cross-database transactions, no migrations tooling, no connection-pool
auto-tuning based on detected `:ractor` vs `:threaded` mode (Q3's decision
was a fixed default plus a loud failure, not automatic detection), no
query-condition DSL beyond equality + `AND`, no live model instances
(Hash-only in/out), no table-name inference/pluralization (explicit
`table_name` only), no associations/validations/callbacks/dirty-tracking.
