# Changelog

All notable changes to this project are documented here. Format is loosely
[Keep a Changelog](https://keepachangelog.com/); versions are as released
in `lib/monk/version.rb`.

## 0.10.0 - 2026-09-09

### Added

- **`Monk::Log` level methods** (`lib/monk/log.rb`, #46): `.debug`/`.info`/
  `.warn`/`.error` for app-level logging, each writing one `LEVEL message`
  line to the existing `log/<env>.log` when at or above the configured
  threshold, a no-op otherwise. Distinct from `#write`, `Log`'s existing
  unconditional per-request access-log line, which no threshold gates.
- **`LOG_LEVEL` setting** (`lib/monk/settings.rb`, #46): a new
  `Settings`-backed key, implicit like `MONK_ENV` (no app `configure`
  call needed), one of `debug`/`info`/`warn`/`error` (`info` default),
  validated at `Boot` and resolved once into `Log`'s threshold rather
  than read per call.

## 0.9.0 - 2026-09-09

### Added

- **WebSocket cross-process fan-out over Redis** (`Monk::WebSocket::RedisFanout`,
  `lib/monk/websocket/redis_fanout.rb`, #43): wraps a `Registry` with the
  identical `#register`/`#unregister`/`#count`/`#broadcast` interface, so
  swapping which object a connection holds is the only change an app
  makes. `#broadcast` still delivers to this process's own `Registry`
  directly (same latency and reliability as a plain `Registry`, even if
  Redis is briefly down) and publishes to Redis so sibling
  `Monk::WebSocket::Server` processes relay it to their own connections;
  every publish carries a per-instance origin id so a process's own
  publish, echoed back to it over Redis, is dropped instead of delivered
  twice. Chosen over Postgres `LISTEN`/`NOTIFY` — no payload cap, higher
  throughput, and the `redis` gem's pub/sub client is Ractor-ready.
- **`monk new` scaffolds `bin/websocket_server` unconditionally, plus a new
  `--redis` opt-in** (#43): unlike `--postgres`/`--redis`, plain WebSocket
  needs no external service, so it isn't gated behind a flag — every
  scaffolded app gets a working `bin/websocket_server` (a single `:chat`
  broadcast channel) that adapts at boot instead: `authenticate: true`
  automatically if `--auth`'s `config/auth.rb` is present, `RedisFanout`
  instead of a plain `Registry` automatically if `REDIS_URL` is set.
  `--redis` (`monk new my_app --redis`) is fully independent of
  `--postgres`/`--auth` and adds only a `Gemfile` line — there's no
  `config/redis.rb`, since `REDIS_URL` is read directly the same way
  `WS_PORT`/`WS_ALLOWED_ORIGINS` already are.

### Fixed

- **`RedisFanout` wasn't actually usable the way it needed to be** (#43),
  found by running it against a real Redis rather than trusting the
  design: it held a live `Redis` client directly on an unfrozen instance
  and never called `freeze`, so it wasn't `Ractor.shareable?` at all
  (`Ractor::IsolationError` the moment a connection Ractor read it from a
  module constant, the same way `Registry` already is); `CHANNEL_PREFIX`
  was an unfrozen String constant, hit by the same error from inside the
  subscriber Ractor; and the subscriber recovered a Redis channel name as
  a String and broadcast with it directly, silently landing on a
  different `Hash` key than the Symbol every real caller registers under
  — `#broadcast` returned `true` while delivering to nobody. Fixed with a
  lazy, per-Ractor publisher (mirrors `Monk::Persistence::Registry`),
  `freeze` at the end of `#initialize` (mirrors `Registry`), and `.to_sym`
  on the recovered channel name.

## 0.8.0 - 2026-09-07

### Added

- **`Base.resources`** (experimental, `lib/monk/base.rb`, #35): registers
  the seven conventional REST routes (index/new/create/show/edit/update/
  destroy) for a resource in one call, each dispatching to
  `controller.new(context).public_send(action)`. Built entirely on the
  existing `get`/`post`/`put`/`patch`/`delete`, so it doesn't touch
  routing, dispatch, or `freeze!` — purely additive.
- **File-based request logging** (`lib/monk/log.rb`, #34): every request
  now appends a line to `log/<env>.log`, Rails-style (development/test/
  staging/production each get their own file), unconditionally across
  all environments. The existing `$stdout` echo (with its per-line
  flush) stays gated to development, unchanged.
- **`--auth` scaffold opt-in** (`monk new my_app --auth`, #36): scaffolds
  `config/auth.rb` and a migration creating the `login_tokens`/`sessions`
  tables `Monk::Auth` needs. Implies `--postgres` — Auth is
  Postgres-only, so this always brings the persistence scaffold with it.
- `monk new` now also scaffolds `bin/server` and a project `.gitignore`
  (`/log/`, `.env`/`.env.*`, keeping `.env.example`) as part of the base
  skeleton.
- **`Pg::Model.where`**: accepts comparison operators (`gt:`/`gte:`/
  `lt:`/`lte:`/`ne:`) and `column: [v1, v2]` for `IN`, plus a trailing
  options `Hash` for `order:`/`limit:` — previously equality-only. `OR`
  stays out of scope; composite conditions still need a raw `Pg.checkout`
  block.
- **`Pg::Model.find_all`/`.create_all`**: `find_all(ids)` does one
  `SELECT ... WHERE id IN (...)` round trip, returning rows positionally
  matched to `ids` (`nil` for any missing, consistent with `find`).
  `create_all(rows)` does one multi-row `INSERT ... VALUES ...
  RETURNING *`; every row must share the same set of keys.
- **WebSocket `Server` heartbeat and reverification** (#39, #40):
  `ping_interval:` spawns a per-connection thread sending an unsolicited
  ping on that cadence, so a spec-compliant client's automatic pong
  resets a reverse proxy's idle timer even on an otherwise-idle browser
  connection. `reverify_interval:` (requires `authenticate: true`)
  re-runs `Monk::Auth.verify` against the same credential on that
  cadence and closes the connection (RFC 6455 code 1008) the moment
  verify comes back `nil`. Both default to `nil` (off).
- **WebSocket `Connection` fragmentation reassembly and a payload cap**
  (#41): `#read` now reassembles a fragmented message (`fin: false`
  starts it, opcode `0x0` continues it, `fin: true` ends it) instead of
  returning the first fragment as if it were the whole message, closing
  with 1002 on an out-of-sequence fragment. `max_payload_size:` (1 MiB
  default, always on) rejects any single frame — or a fragmented
  message's reassembled total — over the cap with 1009, checked before
  ever attempting to buffer it.
- `Monk.boot` now logs a startup line reporting the running environment,
  route count, and (only when actually configured) `auth=on` and which
  `Persistence::Registry` backends have registered connections;
  `Persistence::Registry` gained a public `#names` reader backing that.

### Fixed

- **WebSocket `Registry#broadcast`** (#38): a port that closed without
  ever going through `#unregister` (e.g. its owning connection Ractor
  died first) raised `Ractor::ClosedError` unguarded inside the
  registry Ractor's own loop, killing delivery for every key in the
  whole process, not just the dead connection's one. `#broadcast` now
  skips a closed port, keeps delivering to the rest of that key's
  subscribers, and drops the dead port so it isn't retried.

### Changed

- **Error classes reorganized by subsystem** (#42): each subsystem's
  error classes now live in a single `errors.rb` next to the code that
  raises them (`auth/`, `persistence/`, `persistence/pg/`, `websocket/`),
  rather than 19 one-class-per-file error files at the `lib/monk/` root.
  Errors shared by single-file subsystems (settings, views/templates,
  scaffold, Ractor-sharing) land in a shared `lib/monk/errors.rb`.

## 0.7.0 - 2026-09-05

### Added

- **Settings** (`lib/monk/settings.rb`, #32): `Monk::Settings.configure`
  declares required/optional keys via a small DSL; `Settings[:key]` reads
  each key's value from `ENV` (uppercased name) or its default.
  Declaring the same key twice, or reading one nobody declared, raises a
  precise error (`DuplicateSettingError`/`UnknownSettingError`) instead
  of silently overwriting or returning `nil`. Joins `Monk.freeze_hooks`:
  `Base#freeze!` validates every required key is present and freezes the
  resolved values into a `Ractor.shareable?` snapshot
  (`MissingSettingError` otherwise; `SettingsFrozenError` on a
  post-Boot `#configure`). `Context#settings` exposes the same frozen
  reads to routes.
  - `MONK_ENV` is now a first-class Settings key, implicitly declared
    and validated at Boot against a fixed four-value set
    (development/test/staging/production) — an invalid value raises
    `InvalidMonkEnvError`. `Monk.env` returns a frozen `Environment`
    value object with `.development?`/`.test?`/`.staging?`/
    `.production?` predicates, replacing ad hoc `ENV["MONK_ENV"] ==
    "production"` checks in assets and request logging.
  - `monk new` scaffolds now ship `config/settings.rb` (loads `dotenv`
    if present, otherwise a no-op) required ahead of the app class body
    and the `--postgres` `bin/` scripts.
  - Verified under real concurrent Ractor workers, including an
    end-to-end proof in `monk-consumer-test` under a multi-worker `kino`
    pool.
- Routes are now indexed at Boot for O(1) static dispatch (#33):
  `freeze!` builds a static verb/path hash for exact-match routes and a
  per-verb array of dynamic routes with segments precomputed, instead of
  `find_route` linearly re-splitting every registered route's path on
  every request. Params hashes are now only allocated once a route is
  confirmed to match. `bin/benchmark_router` (manual) shows ~210x on a
  static route, ~31x on a 404 miss, and ~5x on a dynamic route at a
  300-route table.

## 0.6.0 - 2026-09-05

### Added

- **WebSockets** (`lib/monk/websocket.rb`, opt-in via
  `require "monk/websocket"`): a hand-rolled RFC 6455 implementation —
  handshake and frame codec (all three length encodings; `ProtocolError`
  on truncated/malformed frames), a connection-per-Ractor server
  (`Monk::WebSocket::Server.new(port:, bind:)`) that moves each accepted
  socket into its own Ractor via `Ractor#send(..., move: true)` so one
  slow or crashing connection never blocks the accept loop or any other
  connection, and a full close handshake (server- and client-initiated,
  plus abrupt-disconnect handling) reported to app code as a plain `nil`
  read.
  - `Registry`: an in-process broadcast Ractor (`register`/`unregister`/
    `broadcast`) that connections subscribe to by key; broadcasts relay
    onto each subscriber's socket from a background thread inside that
    connection's own Ractor, with unconditional unsubscribe in `ensure`
    so no lifecycle path leaks a stale entry.
  - `Server.new(authenticate: true)` extracts identity via
    `Monk::Auth` — `Authorization: Bearer` or the `session_token`
    cookie — with `allowed_origins:` origin checking for
    cookie-derived credentials; ping/pong is answered automatically
    without reaching app code.
  - Verified under real concurrent Ractor workers (ordinary, slow, and
    crashing connections running simultaneously; broadcast from a
    fourth, independent Ractor to multiple real subscribers).

### Fixed

- `Monk.freeze!` is now callable independent of `Base#freeze!`: a
  WebSocket-only app never touches `Monk::Base`, so nothing was freezing
  `Monk::Auth`'s config and the first `Monk::Auth.verify` call from a
  connection Ractor raised `Ractor::IsolationError`. `Server.new
  (authenticate: true)` now freezes on first use, mirroring `Base.call`.

## 0.5.0 - 2026-09-05

### Added

- **Views** (`lib/monk/views.rb`): ERB templates under `views/` (or a path
  set via `views`), compiled once at Boot into instance methods on a
  module `Context` includes — never at request time, since a worker
  Ractor can hold no template cache and must not install methods on a
  shared module. A broken template fails Boot naming file and line.
  `<%= %>` HTML-escapes by default (a deliberate break from stock ERB);
  `raw(x)` opts out, `h(x)` escapes explicitly without double-escaping.
  Layouts are Ruby's own `yield`, applied to the outermost `render` of a
  request only. Data reaches a template as ivars set in the route and as
  a `locals` hash passed to `render`.
- **Static assets** (`lib/monk/assets.rb`): `public/` is walked at Boot
  into a frozen manifest (body, content-type, ETag) served before routes
  for `GET`/`HEAD`. Production serves an exact-match fetch from that
  manifest (path traversal is structurally impossible, not defended
  against); development re-reads from disk per request instead, with a
  containment check. ETag/304 support, `must-revalidate` by default, and
  a `?v=` digest stamp from `asset_path` that earns a year of immutable
  caching.
- **Auth** (`lib/monk/auth.rb` and friends, #28): passwordless login —
  token issuance and single-use atomic redemption, session verification
  and revocation, rate limiting, and cookie/redirect support — wired
  through Boot and real Ractor workers.
- `monk new` now scaffolds a working HTML page (layout, index template,
  stylesheet, ES-module entry point) instead of a bare JSON route.

### Fixed

- `Monk::Assets::TEXT_TYPES`/`BINARY_TYPES` were `{ ... }.freeze`, which
  freezes the hash but not the strings inside it, so the constants were
  never actually `Ractor.shareable?`. In development, every static-asset
  request calls `content_type` from the serving worker Ractor, which
  raised `Ractor::IsolationError` on the very first request. Fixed by
  building both hashes with `Ractor.make_shareable` instead.

## 0.4.0 - Phase 4

- `monk new` / `Monk::Scaffold`: scaffolds a new project's skeleton
  (`Gemfile`, `config.ru`, `.ruby-version`, `views/`, `public/`, and
  `--postgres` for persistence/migrations wiring) from static templates.

## 0.3.0 - Phase 5

- `Monk::Persistence::Pg::Migrator`: plain-SQL migrations
  (`<version>_<name>.up.sql` / `.down.sql`), tracked in a
  `schema_migrations` table, run explicitly (never hooked into Boot).

## 0.2.0

- `Monk::Persistence::Pg` and `Monk::Persistence::Pg::Model`: opt-in raw
  Postgres access and CRUD sugar over plain Symbol-keyed hashes, frozen
  and made Ractor-shareable at Boot alongside routes and error handlers.

## 0.1.0 (#18)

- Packaged Monk as a local gem: routing (`get`/`post`/`put`/`patch`/`delete`
  with path params and a trailing splat), `Context`, `error` handlers,
  `Monk.boot`/`.freeze!` sealing the app into a `Ractor.shareable?`
  structure, and `Monk::StateRactor` for state that must be shared and
  mutated safely across Ractor workers.
