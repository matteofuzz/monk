# Monk::Live — Postgres fanout, Redis optional — implementation plan

> **Historical document.** It records how this was planned or built at the time and may describe things that have since changed or shipped. For how Monk works today, see [`docs/guides/`](../guides/).

Branch: not yet created — nothing in this plan is implemented. Companion
doc: `../design/live-pg-fanout.md` (why Redis is currently mandatory for
reasons unrelated to scaling, and the piece-by-piece mapping from
`RedisFanout` this plan turns into phases).

Same posture as `plan-websocket.md`/`plan-live.md`: small red → green
slices, one failing test per seam, minimum code to pass. Ruby 4.0.6,
Ractor behavior measured against a real test Postgres, never assumed from
`RedisFanout`'s own behavior even where the shape looks identical.

## Naming and packaging

`Monk::WebSocket::PgFanout`, in `lib/monk/websocket/pg_fanout.rb`, next to
`redis_fanout.rb`. Opt-in the same way: `require "monk/websocket/pg_fanout"`
explicitly; `require "monk/websocket"` and `require "monk/live"` alone
never load it. Depends only on `pg` (already a dependency wherever
`Monk::Persistence::Pg` is used) and the same `Monk::WebSocket::Registry`
interface `RedisFanout` wraps. No change to `Monk::Live` itself — the
whole point is that `Monk::Live.configure(registry:)` already accepts
anything meeting the four-method contract.

## Decisions locked in before Phase 1

Each of these is a recommendation from `../design/live-pg-fanout.md`
promoted to a plan assumption. Reversing one invalidates the phases that
rest on it.

1. **Same interface, second implementation.** `PgFanout` answers
   `#register`/`#unregister`/`#count`/`#broadcast`, wraps a
   `Monk::WebSocket::Registry`, and is Ractor-shareable after
   construction — a drop-in alternative to `RedisFanout` for
   `Monk::Live.configure(registry:)`, nothing else changes.
2. **One fixed `LISTEN`/`NOTIFY` channel, not one per key.** Postgres has
   no pattern `LISTEN`, unlike Redis's `psubscribe("monk:ws:*")`, so the
   registry key can't live in the channel name. A single channel (e.g.
   `monk_live`) carries every key; the key rides inside the payload
   instead.
3. **Payload envelope: `"<origin>\0<key>\0<payload>"`.** Parsed three ways
   on receipt (origin for echo suppression, key for the registry lookup,
   payload forwarded as-is) — one more split than `RedisFanout`'s
   two-way `sender, payload = envelope.split("\0", 2)`.
4. **Publish via bound-parameter `pg_notify`, never string-built `NOTIFY`.**
   `exec_params("SELECT pg_notify($1, $2)", [channel, envelope])` — avoids
   any quoting/injection concern for payload bytes, which Redis's `PUBLISH`
   never had to worry about in the first place.
5. **Two distinct connection roles, never the app's query pool.** The
   subscriber Ractor opens one dedicated `PG::Connection` and blocks in
   `wait_for_notify` for the process's lifetime; the publish side memoizes
   one `PG::Connection` per calling Ractor
   (`Ractor.current[:monk_pg_fanout_publisher] ||= ...`), mirroring
   `RedisFanout#publisher` and `Monk::Persistence::Pg`'s own per-Ractor
   pattern. Neither is ever the connection `Monk::Persistence::Pg` hands
   out for app queries — a `LISTEN` connection can't run concurrent
   queries, and `NOTIFY` on a connection mid-transaction wouldn't fire
   until commit.
6. **8000-byte payload cap fails loud, before the query runs.**
   `#broadcast` raises a clear `Monk` error (naming the byte count and the
   cap) when `payload.bytesize` exceeds Postgres's `NOTIFY` limit, instead
   of letting `pg_notify` fail with a raw `PG::Error` or silently
   truncating.
7. **Connection info comes from existing `Monk::Settings` DB\_\* values**,
   the same ones `config/persistence.rb` already builds a connection
   string from — no new env var. This is the concrete form of "an app that
   already runs Postgres changes zero configuration to pick this up."
8. **No reconnection/retry logic**, matching `RedisFanout`'s existing
   posture exactly. A dropped connection kills the subscriber Ractor the
   same way on both implementations; this plan doesn't add resilience
   neither implementation has today.
9. **Opt-in, like every other Monk backend.** `require
   "monk/websocket/pg_fanout"` explicitly.
10. **`scaffold.rb` flag semantics are an open question, deferred to its
    own phase (Phase 6), not decided by this list.** Whether `--live`
    should imply `--postgres` instead of `--redis`, and under what
    condition, is a generator-wide behavior change independent of whether
    `PgFanout` itself works.

## Seams

- **Seam A — `PgFanout`'s own interface**, tested directly against a
  wrapped test-double registry with a real test Postgres connection, no
  app process involved — mirrors how `RedisFanout` and `Registry` are each
  tested against their own interface first.
- **Seam B — cross-instance delivery in one process.** Two `PgFanout`
  instances (standing in for two OS processes) sharing the same test
  Postgres, each wrapping its own real `Registry`: broadcast from one
  reaches the other's registered ports, and a broadcast is never
  delivered twice to its own origin's registry.
- **Seam C — real cross-process**, mirroring `plan-live.md` Phase 7: a
  second, genuinely separate OS process (a `PgFanout`-based counterpart to
  `test/support/live_ws_process.rb`) holding the WS connections, publishing
  from the test process's own `PgFanout`.
- **Seam D — `Monk::Live` integration end to end**: `Monk::Live.configure
  (registry: PgFanout.new(...))`, then `patch`/`append`/`prepend`/`remove`/
  `batch` delivered across the Seam C process boundary with the envelope
  intact.

## Phase 1 — `PgFanout` core (Seam A)

1. `PgFanout.new(registry, pg_config:)` (exact keyword TBD at
   implementation time — likely reusing whatever `Hash`/connection-string
   shape `config/persistence.rb` already builds) stores the wrapped
   registry, generates a frozen origin UUID, and freezes `self` once
   construction completes.
2. `#register`, `#unregister`, `#count` — pure delegation to the wrapped
   registry, asserted directly (no Postgres involvement needed for these
   three).
3. Constructing with a non-shareable wrapped registry raises the same
   class of error `RedisFanout`/`Monk::Live.configure` already raise for
   an unshareable registry — checked at construction, not first broadcast.

## Phase 2 — Channel, payload framing, and the size guard (Seam A continued)

4. `#broadcast(key, payload)` delivers to the local wrapped registry
   directly first (same latency/reliability as a plain `Registry` if
   Postgres is briefly unavailable — mirrors `RedisFanout#broadcast`'s own
   ordering), then builds the `"<origin>\0<key>\0<payload>"` envelope and
   calls `pg_notify` via `exec_params` on the calling Ractor's memoized
   connection.
5. A payload whose `bytesize` exceeds 8000 raises before `exec_params` is
   ever called — asserted with a payload built to be exactly one byte over
   the cap, and asserted that exactly at the cap it does not raise.
6. Publish connection is memoized per calling Ractor
   (`Ractor.current[:monk_pg_fanout_publisher]`), asserted by publishing
   twice from the same Ractor and confirming no second connection opens
   (a counting stub or a `PG::Connection#object_id` check).

## Phase 3 — Subscriber Ractor and echo suppression (Seam A/B)

7. The subscriber Ractor opens its own dedicated `PG::Connection`, issues
   `LISTEN monk_live`, and loops on `wait_for_notify`, dispatching each
   notification to the wrapped registry's `#broadcast(key.to_sym,
   payload)` after splitting the envelope and dropping the process's own
   origin.
8. **Seam B test**: two `PgFanout`s sharing one test-Postgres connection
   config, each wrapping its own real `Registry` with a registered
   `Ractor::Port`; broadcasting from instance A's `#broadcast` is observed
   exactly once on B's registered port and **zero** times on A's own
   registered port via the round trip (the origin-echo assertion
   `RedisFanout`'s own test suite already makes, reproduced here).
9. Symbol/String key handling matches `RedisFanout` exactly: the channel
   payload's key segment is always a String on the wire, converted with
   `.to_sym` before reaching `Registry#broadcast`, matching every existing
   caller's Symbol-keyed usage.

## Phase 4 — Real cross-process (Seam C)

10. A `PgFanout`-based counterpart to `test/support/live_ws_process.rb`:
    a genuinely separate OS process running `Monk::Live::HANDLER` on a
    `PgFanout`-wrapped registry, sharing only the test Postgres database
    with the test process.
11. A fragment rendered and broadcast in the test process reaches a real
    WS client connected to the child process, through Postgres only —
    the direct analogue of `plan-live.md` Phase 7's Redis proof, this time
    with `PgFanout`.
12. Non-ASCII/multi-line payload byte-fidelity, re-run here rather than
    assumed: `plan-live.md` Phase 7 found and fixed a real encoding bug in
    the WS frame layer (`Frame.encode`, non-ASCII UTF-8) that had nothing
    to do with the fanout transport — confirming it doesn't regress
    through a different transport is cheap insurance, not busywork.
13. Killing the Postgres connection mid-session is observed as the
    subscriber Ractor dying (no retry, per Decision 8) — asserted
    explicitly so this is documented behavior, not a silent gap discovered
    later.

## Phase 5 — `Monk::Live` wiring, config template, docs (Seam D)

14. `Monk::Live.configure(registry: PgFanout.new(...))` end to end:
    `patch`/`append`/`prepend`/`remove`/`batch`, each asserted delivered
    across the Seam C process boundary with the envelope intact — mirrors
    `plan-live.md` Phase 7's `live_redis_test.rb` and
    `live_multiprocess_browser_test.rb`, this time against Postgres.
15. `config/live.rb` template gains a `PgFanout`-based variant (or a
    conditional within the existing template) that builds its connection
    info from the same `Monk::Settings` DB_\* values `config/persistence.rb`
    already reads — no new `.env` entries for this path.
16. `docs/guides/live.md` documents the choice (when to reach for
    `PgFanout` vs. `RedisFanout`, the 8000-byte cap, that neither retries a
    dropped connection) and `SETUP.md`'s generated "Live updates" section
    reflects whichever transport the generated app actually uses.

## Phase 6 — Scaffold flag semantics — DECISION NEEDED before implementation

Open question 2 from the design doc, deliberately not pre-decided here:

- Today `@redis = redis || live` (`lib/monk/scaffold.rb:97`) makes `--live`
  unconditionally pull in Redis. Candidates:
  (a) `--live` implies `--postgres` (not `--redis`) whenever `--postgres`
  is already requested or implied (e.g. by `--auth`), with `--redis`
  becoming an explicit, separate opt-in;
  (b) `--live` keeps implying `--redis` by default, and an app opts into
  `PgFanout` with a new flag (e.g. `--live-pg` or `--no-redis`);
  (c) `monk new --live` with neither `--postgres` nor `--redis` passed
  prompts or documents the choice rather than picking silently.
- Whichever is chosen, `SETUP.md`'s generated content and `monk help`'s
  flag documentation need the matching wording — this repeats the
  discipline `plan-websocket.md`/`plan-live.md` already applied whenever a
  flag combination changes what gets generated.
- This phase is gated on a decision, not on any remaining technical
  uncertainty — Phases 1-5 fully validate `PgFanout` works regardless of
  how the generator ends up defaulting.

## Explicitly out of scope for this plan

- Building horizontal WS-process scaling (`plan-websocket.md` Decision 4
  stays deferred, unaffected either way).
- Payload chunking/reassembly to work around the 8000-byte `NOTIFY` cap.
- Any change to `Monk::Live`'s public API, wire protocol, or client
  runtime — none of it is transport-aware today and this plan keeps it
  that way.
- Automatic runtime fallback or failover between Postgres and Redis.
- Retrofitting reconnection/retry onto `RedisFanout` — if it's ever added,
  it should land for both implementations together, not as a side effect
  of this plan.

## Risks worth watching

- The 8000-byte cap surprising a real app with a large partial — Phase 2's
  guard makes the failure loud and immediate rather than a mystery, but an
  app that regularly renders large fragments is simply the wrong fit for
  this transport, not a bug to work around later.
- Phase 6's decision blocking on nothing technical, but easy to leave
  unresolved indefinitely since Phases 1-5 are independently useful even
  without a scaffold default — worth revisiting explicitly once Phase 5
  ships, not left to drift.
- `wait_for_notify`'s blocking behavior under a Postgres restart/failover
  is unmeasured here (Phase 4 step 13 only covers a hard connection kill,
  not a graceful failover) — same category of gap `plan-live.md` Phase 7
  left open for Redis ("Redis restarting under a live fanout"), not
  newly introduced by this plan.
