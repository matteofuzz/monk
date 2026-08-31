# Monk persistence — implementation plan

Branch: `main_dev/add_db_support`. Companion doc:
`docs/persistence-ractor-connections.md` (design rationale, facts gathered,
resolved decisions).

**Phase 0 ran on 2026-08-31 and failed for Sequel**: `Sequel.connect` from
any non-main Ractor raises `Ractor::IsolationError` on `Sequel::ADAPTER_MAP`,
with no workaround found (pre-loading the adapter in the main Ractor first
doesn't help — the map is read on every connect, not just written once).
Raw `pg` was tested as the pivot target and works cleanly across Ractors.
Per the pivot criteria below: **Phases 1+ restart with raw `pg` in place of
Sequel**, and the Phase 3 (`DatasetProxy`) design needs to change, since it
was built around delegating to Sequel dataset methods that no longer exist
in this path — see the companion doc's "Phase 0 result" section for the
open question this raises. Phases 1–6 below are left as originally
written (for the record of what was planned pre-spike); do not implement
against them as-is until that open question is resolved.

Like `PLAN.md`, this develops in small, gradual, red → green cycles. Each
numbered step is one vertical slice: one failing test against its seam,
then the minimum code to pass it. Phase 0 is the exception — it's a spike,
not TDD, and it gates everything after it.

## Seams

- **Seam E — `Monk::Persistence`'s own public API**: registry and
  per-Ractor connection lifecycle, tested directly against its own
  interface (mirrors how `PLAN.md` Seam C tested `StateRactor`).
- **Seam F — `Monk::Persistence::DatasetProxy`**: the shareable-handle
  ergonomics layered on top of Seam E.
- **Seam B (extended) — `.freeze!` / boot**: whether persistence
  registration needs any boot-time validation of its own, alongside the
  route/handler shareability checks it already does.
- **Seam G — real concurrent Ractor integration**: multiple real Ractors
  actually hitting a live Postgres through Seam E/F at once — the
  persistence equivalent of `PLAN.md` Seam D, and the only place that
  proves the premise holds under real parallelism.
- **Seam H — `monk-consumer-test` end-to-end**: the gem consumed from
  *outside* the repo, via the `path:` dependency, boots for real and
  serves a request that round-trips to Postgres.

## Phase 0 — Spike: does Sequel survive across Ractors? (gates everything below)

Not TDD — a throwaway experiment to resolve the one open empirical
question from the design doc: `Sequel::ADAPTER_MAP`/`SHARED_ADAPTER_MAP`
are unfrozen, module-level, lazily-populated hashes with no
`keep_reference`-style opt-out. Does a second Ractor calling
`Sequel.connect(adapter: "postgres", ...)` after a first Ractor already
populated that hash work correctly, or does it hit `Ractor::IsolationError`
/ corrupt state / silently misbehave?

Steps:

1. Start the disposable Postgres container (`docker run --rm -e
   POSTGRES_PASSWORD=... -p 5432:5432 postgres`).
2. In a scratch script (not committed), install `pg` + `sequel` in a
   throwaway `Gemfile`, then:
   - `Ractor.new { Sequel.connect(adapter: "postgres", ..., keep_reference:
     false) }` — first Ractor, populates `ADAPTER_MAP` for the first time.
   - A second, separate `Ractor.new { Sequel.connect(...) }` — does this
     one raise, hang, or succeed?
   - If it succeeds: run an actual query (`db[:pg_stat_activity].count` or
     similar) from each Ractor to confirm the connection isn't just
     constructed but usable.
3. Record the result (pass/fail, exact error class/message if it fails) in
   `docs/persistence-ractor-connections.md` under a new "Phase 0 result"
   heading.

**Result (2026-08-31): failed, no workaround, pivot triggered.** Sequel
raises `Ractor::IsolationError: can not access non-shareable objects in
constant Sequel::ADAPTER_MAP by non-main ractor.` from any non-main
Ractor, in every configuration tried, including pre-loading the adapter in
the main Ractor first. Raw `pg` was verified as the fallback and works
cleanly across Ractors. Full detail: `docs/persistence-ractor-connections.md`
→ "Phase 0 result." See the top of this file for what changes as a result.

**Pivot criteria** (per the design doc's "exploratory, ready to change
approach" framing): if Phase 0 fails and there's no viable workaround
(e.g. forcing `require "sequel/adapters/postgres"` once in the main
Ractor before any workers spin up, so `ADAPTER_MAP` is populated before
the hash is ever touched concurrently — worth trying as a fix before
declaring Sequel unworkable), fall back to raw `pg` directly (Option 1 from
the design doc's comparison table) and restart this plan from Phase 1 with
`pg` in place of `Sequel` throughout. Do not proceed to Phase 1 on
Sequel until Phase 0 passes.

## Phase 1 — Registry & config (Seam E)

4. `Monk::Persistence.register(:name, **opts)` stores the config for later
   lookup.
5. `Monk::Persistence[:name]` raises a precise error (naming the missing
   key) for an unregistered name — fail fast, per ADR 0003's spirit.
6. `Monk::Persistence.register` always merges in `keep_reference: false`,
   regardless of what the caller passed — verify a caller-supplied
   `keep_reference: true` is overridden, not merged the other way.
7. `Monk::Persistence[:name]` lazily creates a `Sequel::Database` on first
   call within a Ractor, and memoizes it — a second call from the *same*
   Ractor returns the identical object (test via `equal?`).
8. `max_connections` defaults to `1` when not specified in `register`'s
   opts; an explicit `max_connections:` in `register` overrides the
   default.

## Phase 2 — Pool-exhaustion robustness (Seam E)

9. A `Sequel::PoolTimeout` raised during checkout is caught and re-raised
   as `Monk::PersistenceTimeoutError`, whose message names the pool/database
   key and points at `max_connections` as the relevant config.

## Phase 3 — `DatasetProxy` (Seam F)

10. `Monk::Persistence.dataset(:db, :table)` returns an object for which
    `Ractor.shareable?` is `true` immediately (before any connection is
    ever made) — it holds only two frozen `Symbol`s.
11. Calling a Sequel dataset method (`.where`, `.all`, `.count`, ...) on the
    proxy delegates to the real dataset resolved via
    `Monk::Persistence[:db][:table]`, and returns the same result the
    direct call would.
12. `respond_to?` on the proxy reflects the real dataset's methods (via
    `respond_to_missing?`), so introspection/duck-typing on it doesn't lie.

## Phase 4 — Boot integration (Seam B extended)

13. Confirm `.freeze!` does *not* need special-casing for `register`'d
    configs — they're plain Hashes of primitive values (Strings, Symbols,
    Integers), already `Ractor.shareable?` by construction. Write a test
    asserting this rather than assuming it.
14. Decide (test-first) whether `.freeze!` should validate that every name
    referenced by a `DatasetProxy` built at app-definition time was
    actually `register`'d — catching a typo'd `:analytics` vs
    `:analitics` at boot instead of at first request. If yes: `.freeze!`
    raises a precise error naming the unregistered key.

## Phase 5 — Real Ractor integration against live Postgres (Seam G)

15. Multiple real Ractors calling a route that reads via `DatasetProxy`
    concurrently, against the live (Dockerized) Postgres from Phase 0, all
    succeed with correct, independent results — the actual proof this
    design exists for. Mirrors `PLAN.md` step 19.
16. Multiple real Ractors *writing* concurrently (distinct rows, e.g. each
    Ractor inserts its own worker id) never lose or corrupt a write —
    mirrors `PLAN.md` step 20's race-safety proof, but for connections
    instead of `StateRactor`.
17. Force a same-Ractor, multi-checkout-at-once scenario (e.g. two threads
    inside one Ractor, simulating `:threaded` mode, both requesting a
    connection from a `max_connections: 1` pool) and confirm the
    `Monk::PersistenceTimeoutError` path from Phase 2 actually triggers as
    designed under real contention, not just against a mocked
    `Sequel::PoolTimeout`.

## Phase 6 — `monk-consumer-test` end-to-end proof (Seam H)

18. Add a route to `monk-consumer-test`'s `config.ru` that uses
    `Monk::Persistence`/`DatasetProxy` against the Dockerized Postgres.
19. Boot it for real via `bundle exec rackup config.ru` (or under Kino, if
    `monk-consumer-test` is extended to depend on it) and hit it with
    `curl`, confirming the response reflects real data from Postgres.
    Manual smoke test, not CI — mirrors `PLAN.md` step 21's treatment of
    Kino verification.

## Explicitly out of scope for this plan

Carried over from the design doc's own scope cuts: no ActiveRecord
support, no SQLite support (blocked upstream), no cross-database
transactions, no migrations tooling, no connection-pool auto-tuning based
on detected `:ractor` vs `:threaded` mode (Q3's decision was a fixed
default plus a loud failure, not automatic detection).
