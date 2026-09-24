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

## Phase 1 — `PgFanout` core (Seam A) — DONE 2026-09-24

Built as `Monk::WebSocket::PgFanout` in `lib/monk/websocket/pg_fanout.rb`,
tests in `test/websocket_pg_fanout_test.rb` (4 tests this phase).

1. `PgFanout.new(registry, pg_opts:)` — `pg_opts:` is the same
   `{host:, port:, user:, password:, dbname:}` Hash shape
   `config/persistence.rb`/`PersistenceTestHelpers#pg_test_opts` already
   use for `PG.connect`, not a connection-string keyword. Stores the
   wrapped registry, generates a frozen origin UUID, and freezes `self`.
2. `#register`, `#unregister`, `#count` — pure delegation, asserted
   directly.
3. Constructing with a non-shareable wrapped registry raises
   `ArgumentError`, checked on the argument *before* anything opens a
   Postgres connection (Phase 3 changed what "anything" means here — see
   below).

**Found along the way:** `pg_opts`'s String values (host/user/password,
typically from `ENV.fetch`) aren't frozen just because the wrapping Hash
is — `Hash#freeze` doesn't recurse. The shareability check needs
`Ractor.make_shareable(pg_opts.dup)`, not a plain `.freeze`, or it fails
on the connection options instead of the registry argument it's meant to
guard — the same trap `Monk::WebSocket::Server#initialize` already
sidesteps for `allowed_origins`.

## Phase 2 — Channel, payload framing, and the size guard (Seam A continued) — DONE 2026-09-24

Tests added to the same file (6 total after this phase).

4. `#broadcast(key, payload)` delivers to the local wrapped registry
   directly first (same latency/reliability as a plain `Registry` if
   Postgres is briefly unavailable — mirrors `RedisFanout#broadcast`'s own
   ordering), then builds an envelope and calls `pg_notify` via
   `exec_params` on the calling Ractor's memoized connection.
5. A payload whose envelope `bytesize` reaches the cap raises before
   `exec_params` is ever called — asserted with an envelope built to be
   exactly one byte over, and asserted that exactly at the boundary it
   does not raise.
6. Publish connection is memoized per calling Ractor
   (`Ractor.current[:monk_pg_fanout_publisher]`).

**Found along the way, both corrections to this plan's original
assumptions, not just implementation details:**

- **A NUL byte can't ride in a Postgres `NOTIFY` payload at all.**
  `exec_params` raises `ArgumentError: string contains null byte` for any
  bound text parameter containing one — this isn't a `pg`-gem quirk, it's
  that a `NOTIFY` payload is a `text` value and Postgres's `NOTIFY`
  command doesn't support embedded NULs, full stop. Step 4's originally
  planned `"<origin>\0<key>\0<payload>"` framing (`RedisFanout`'s own
  shape) is impossible here. Replaced with a Netstring-style length
  prefix (`"<bytesize>:"` then that many bytes) for origin and key, immune
  to whatever bytes the key or payload contain, since the header's
  delimiter is always the *first* `:` in the whole string by
  construction. Forced through `.b` throughout so byte-length slicing
  lines up for non-ASCII content too — the same class of fix
  `Frame.encode` needed (`docs/history/plan-live.md` Phase 7).
- **The real cap is exclusive, not inclusive, and it's 8000, not
  "≤8000."** Verified directly against a real server (`psql` loop, not
  documentation): 7999 bytes succeeds, exactly 8000 fails with "payload
  string too long." `MAX_NOTIFY_PAYLOAD_BYTES = 8000` and the guard checks
  `>= MAX_NOTIFY_PAYLOAD_BYTES`, not `>` — this plan's step 5 wording
  ("exceeds 8000") would have let a 8000-byte envelope through the guard
  and straight into a raw `PG::Error`, the exact failure mode the guard
  exists to prevent.
- Confirmed via a second `psql` check: multi-byte UTF-8 text survives a
  `pg_notify`/bound-parameter round trip byte-for-byte (see Phase 4's
  fidelity test) — not assumed just because the framing is byte-safe.

## Phase 3 — Subscriber Ractor and echo suppression (Seam A/B) — DONE 2026-09-24

Tests added to the same file (8 total after this phase).

7. The subscriber Ractor opens its own dedicated `PG::Connection`, issues
   `LISTEN monk_live`, and loops on `wait_for_notify`, dispatching each
   notification to the wrapped registry's `#broadcast(key.to_sym,
   payload)` after decoding the envelope and dropping the process's own
   origin.
8. **Seam B test**: two `PgFanout`s sharing one test-Postgres connection
   config, each wrapping its own real `Registry` with a registered
   `Ractor::Port`; broadcasting from instance A's `#broadcast` is observed
   exactly once on B's registered port and **zero** times on A's own
   registered port via the round trip.
9. Symbol/String key handling matches `RedisFanout` exactly: the wire
   key is always a String, converted with `.to_sym` before reaching
   `Registry#broadcast`.

**Deviation from this plan's original ordering:** the registry
shareability check (Phase 1, step 3) now runs *before* the subscriber
Ractor is spawned, not just before `freeze`. Construction from this phase
on always opens a real `LISTEN` connection (no lazy/offline path, matching
`RedisFanout`); checking the argument first means a non-shareable registry
never leaves a live Postgres connection running past a failed
construction. Full suite green (481 runs, 0 failures, 0 skips) after this
phase.

## Phase 4 — Real cross-process (Seam C) — DONE 2026-09-24

`test/support/live_ws_process_pg.rb`, `test/live_multiprocess_helpers_pg.rb`,
`test/live_pg_test.rb` (4 tests).

10. A `PgFanout`-based counterpart to `test/support/live_ws_process.rb`:
    a genuinely separate OS process running `Monk::Live::HANDLER` on a
    `PgFanout`-wrapped registry, sharing only the test Postgres database
    with the test process. Its readiness probe couldn't mirror Redis's
    `CLIENT LIST` `psub=` count (Postgres has no per-channel subscriber
    count) — uses `pg_stat_activity` instead: a backend that issued
    `LISTEN monk_live` and is now blocked in `wait_for_notify` shows up
    `state = 'idle'` with `query = 'LISTEN monk_live'` (Postgres keeps an
    idle backend's last query text), which is exactly the observable
    signal needed.
11. A fragment rendered and broadcast in the test process reaches a real
    WS client connected to the child process, through Postgres only —
    the direct analogue of `plan-live.md` Phase 7's Redis proof, with
    `PgFanout`.
12. Non-ASCII/multi-line payload byte-fidelity, re-run here rather than
    assumed — **scaled down from `live_redis_test.rb`'s ~130KB fixture**,
    which would trip `PgFanout`'s own payload cap outright rather than
    testing fidelity; 40 repetitions (comfortably under the cap) of the
    same quotes/backslash/tab/multi-byte-Unicode line survives the
    length-prefixed envelope and the Postgres hop byte-for-byte.
13. **Killing the Postgres connection mid-session — checked with a
    one-off probe (not a permanent test), same posture `plan-live.md`
    Phase 7 took for "if Redis is down."** Terminating a subscriber's
    backend (`pg_terminate_backend`) kills that Ractor with a reported,
    uncaught `PG::ConnectionBad` (`PQconsumeInput() server closed the
    connection unexpectedly`) — Ruby prints it as a terminated-Ractor
    warning, the process keeps running, and there is no retry, exactly
    `RedisFanout`'s existing posture for a dead connection. A sibling
    fanout's own publish leg (a separate connection) is unaffected and
    keeps succeeding.

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
