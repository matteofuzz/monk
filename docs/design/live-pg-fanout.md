# Monk::Live without Redis: Postgres as the cross-process fanout transport

Status: design exploration, 2026-09-24. Prompted by `../standup-quiz` (a
dozen users at most), where `monk new --live` pulls in Redis purely because
of how `Monk::Live` is currently wired, not because the app needs it.
Companion doc: `../history/plan-live-pg-fanout.md` (the implementation
plan this doc turns into phases).

## Why Redis is there today, precisely

It is easy to read `--live implies --redis` (`lib/monk/scaffold.rb`) as "Redis
is for scaling." It isn't, currently. Two separate facts are being
conflated:

1. **`Monk::WebSocket::Server` is architecturally a second OS process**,
   never co-located with Kino — Kino never exposes a raw socket to Ruby,
   hijack included (`docs/design/websocket.md`, spiked and confirmed). This
   is fixed and not up for revisiting here.
2. **Horizontal scaling of the WS process itself (N processes instead of
   one) is still deferred** — `docs/history/plan-websocket.md` Decision 4:
   "One `Monk::WebSocket::Server` process to start… revisit only if a real
   scaling need shows up." Nothing in this repo builds that today.

Redis is required for neither reason on its own. It is required because
fact 1 means **`config.ru` (where `Monk::Live.patch`/`append`/etc. get
called from HTTP routes) and `bin/websocket_server` (where the WS
connections actually live) are always two different OS processes**, even
at N=1 WS process and a dozen users. A plain in-process
`Monk::WebSocket::Registry` in `config.ru`'s process can never reach a
connection held by `bin/websocket_server`'s process — there is no shared
memory, and Ractors don't cross a process boundary. Something has to carry
the publish across that boundary. Redis pub/sub is the transport Monk
picked for that (`docs/design/websocket.md` Open Question 3, `plan-websocket.md`
Decision 6) — chosen over Postgres `LISTEN`/`NOTIFY` for the *general*
case (no payload cap, higher throughput). It was never re-evaluated for
the "one WS process, a dozen users, app already runs Postgres" case, which
is what this doc does.

## The registry contract is already transport-agnostic

`Monk::Live.configure(registry:)` (`lib/monk/live.rb:53-63`) doesn't know or
care what `registry` is. It only requires:

- Ractor-shareable (checked at configure time, not on a live request), and
- answers `#register(key, port)`, `#unregister(key, port)`, `#count(key)`,
  `#broadcast(key, payload)`.

`Monk::WebSocket::RedisFanout` is one implementation of that contract,
wrapping a plain `Registry` and adding cross-process delivery. Nothing
about `Monk::Live` itself, or the wire protocol, or the client runtime,
mentions Redis. Swapping the transport is entirely a
`config/live.rb`-and-below concern — the idea explored here is a **second**
implementation of the same four-method contract,
`Monk::WebSocket::PgFanout`, that an app already running Postgres can pass
to `configure(registry:)` instead.

## Shape of `PgFanout`, mapped from `RedisFanout` piece by piece

Read alongside `lib/monk/websocket/redis_fanout.rb`, which this mirrors
structurally but not line-for-line — three places are genuinely different,
not just a syntax swap.

**Construction/freeze.** Same shape: store the wrapped registry, generate
a frozen origin UUID (echo suppression), start a subscriber Ractor, freeze
`self`. Different: no new env var. `config/persistence.rb` already builds
a Postgres connection from `Monk::Settings`' `DB_HOST`/`DB_PORT`/`DB_USER`/
`DB_PASSWORD`/`DB_NAME`. `PgFanout` reuses that connection info rather than
inventing a parallel `PG_FANOUT_URL` — an app that already has Postgres
configured needs to change nothing in its environment to pick this up.

**Channel/payload framing — genuinely different.** Redis's subscriber
does `psubscribe("monk:ws:*")`, so the registry key rides in the channel
name (`monk:ws:<key>`) for free. Postgres has no pattern `LISTEN` and
channel names follow SQL identifier rules, so the key can't live in the
channel. `PgFanout` uses one fixed channel (e.g. `monk_live`) and folds
origin, key and payload together into the notification payload itself
(`"<origin>\0<key>\0<payload>"`), parsed three-ways on receipt instead of
Redis's two.

**The publish call — genuinely different.** Not a string-built
`NOTIFY channel, 'payload'` (quoting/injection risk for arbitrary payload
bytes), but Postgres's built-in `pg_notify(channel, payload)` function
called through a bound parameter (`exec_params("SELECT pg_notify($1, $2)",
[...])`), the same way the rest of this codebase never string-interpolates
into SQL.

**Connection ownership — genuinely different.** Redis's `#publisher`
memoizes one client per calling Ractor (`Ractor.current[:...] ||= ...`),
mirroring `Monk::Persistence::Pg`'s own per-Ractor pattern
(`docs/design/persistence-ractor-connections.md`). `PgFanout` does the same for
its *publish* side. But its *subscriber* Ractor's connection sits blocked
in `wait_for_notify` indefinitely — it can never also run ordinary
queries — so it must be a raw, dedicated `PG::Connection`, never borrowed
from `Monk::Persistence::Pg`'s app query pool. There's a second reason to
keep it dedicated: `NOTIFY` is transactional — a notification issued
inside an open transaction on a connection doesn't actually send until
that transaction commits. A connection `PgFanout` owns exclusively, used
for nothing but one-off notify calls, never sits inside an app-started
transaction, so this can't bite by construction.

**`#register`/`#unregister`/`#count` — unchanged.** Pure delegation to the
wrapped `Registry`, identical to `RedisFanout`. Nothing here is
Redis- or Postgres-specific.

## Where this is worse than Redis, honestly

- **8000-byte payload cap**, hard, server-side, Postgres's own limit on a
  `NOTIFY` payload. Redis has none. Live's payloads are rendered HTML
  fragments — tiny for a counter demo, plausibly larger for a real list
  re-render. `PgFanout#broadcast` should check `payload.bytesize` and raise
  a clear `Monk` error *before* ever calling `pg_notify`, rather than
  chunking/reassembling (real complexity for a "keep this simple" feature)
  or letting a cryptic `PG::Error` surface from inside `exec_params`.
- **No reconnection logic**, on either side — this is not new; `RedisFanout`
  doesn't retry a dropped connection either, and this doc doesn't propose
  changing that posture for either implementation.
- **Delivery guarantee is a wash, not actually worse.** Both `NOTIFY` and
  Redis pub/sub are fire-and-forget: a notification with no active listener
  is simply dropped, no queue, no replay. `docs/design/websocket.md`'s framing
  of this as a `NOTIFY`-specific downside undersells that Redis pub/sub
  carries the identical property.
- **Lower throughput than Redis at real scale** — irrelevant at a dozen
  users pushing occasional small patches; the reason to *not* reach for
  this if an app later needs many WS processes or a hot, frequently-patched
  topic.

## Who this is for

An app that (a) already runs Postgres for something else (persistence,
`Monk::Auth`) and (b) is nowhere near needing more than one WS process or
high-frequency broadcasts on a single topic. `../standup-quiz` is exactly
this shape. An app with **no** Postgres dependency gets no benefit —
`PgFanout` would trade one piece of infrastructure for another, not
eliminate one. An app anticipating real horizontal scale should stay on
`RedisFanout`; nothing here changes that recommendation for the general
case, only adds a cheaper option for the common small case.

## Open questions

1. **Oversized-payload behavior**: raise-before-notify (recommended above)
   vs. any softer fallback. No case for a softer fallback has come up;
   this doc treats it as decided unless the plan's tests find one.
2. **`scaffold.rb` flag semantics.** Today `@redis = redis || live`
   unconditionally (`lib/monk/scaffold.rb:97`). Whether `--live` should
   instead imply `--postgres` (not `--redis`) when Postgres is already in
   play, with `--redis` becoming an explicit opt-in for apps that want it
   regardless, is a real behavior change to the generator's flag matrix —
   deliberately left to the plan's own phase rather than decided here,
   since it affects every future `monk new --live` invocation, not just
   this transport choice.
3. **Does `config/live.rb` offer both, or auto-pick one?** A generated app
   with both `--postgres` and `--redis` explicitly passed has no forced
   choice; the template needs to pick a default or ask. Not resolved here.

## Explicitly out of scope (for this doc)

- Building horizontal WS-process scaling — still deferred, per
  `plan-websocket.md` Decision 4, unaffected by anything here.
- Payload chunking/reassembly across multiple `NOTIFY` calls to work around
  the 8000-byte cap.
- Changing `Monk::Live`'s public API, wire protocol, or client runtime —
  none of it is transport-aware today and none of it needs to become so.
- Automatic runtime fallback from Postgres to Redis or vice versa.

## Recommendation

Build `Monk::WebSocket::PgFanout` as a second, opt-in implementation of the
existing registry contract, following `RedisFanout`'s shape with the three
differences above (channel/payload framing, dedicated connections,
bound-parameter `pg_notify`), and let `config/live.rb` use it when an app
already has Postgres and doesn't ask for `--redis`. Redis stays the
default recommendation once real scaling is in view; this only removes it
as a *mandatory* piece of infrastructure for the common small-app case.
