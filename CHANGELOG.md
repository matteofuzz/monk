# Changelog

All notable changes to this project are documented here. Format is loosely
[Keep a Changelog](https://keepachangelog.com/); versions are as released
in `lib/monk/version.rb`.

## Unreleased

### Fixed

- **`Monk::WebSocket::Frame.encode` raised `Encoding::CompatibilityError` for
  any UTF-8 text containing non-ASCII characters** (`"caffè"`, `"☃"`, an
  emoji): the frame header is a BINARY string holding a non-ASCII byte and
  can't be concatenated with such a payload. Only ASCII text and BINARY
  payloads (which is all a client message ever is, so echoing chat worked)
  were sendable. The payload is now sent as bytes. Found by the Monk::Live
  cross-process tests, where a fragment with an accent silently never
  arrived.

## 0.12.5 - 2026-09-18

### Added

- **`Monk::Auth.log_dev_link(link, subject: nil)`** (`lib/monk/auth.rb`):
  in development only, prints a magic link to stdout and the dev log, plus a
  scannable QR code beneath it when the app's own Gemfile includes the
  optional `rqrcode` gem. A no-op outside development.

### Fixed

- **`log_dev_link`'s QR code raised `Ractor::IsolationError` inside a worker
  Ractor**: `rqrcode` has unfrozen lookup-table constants that can't be read
  from a non-main Ractor. `Monk::Auth` now walks the `RQRCode` /
  `RQRCodeCore` constants at boot and makes them shareable.
- **`log_dev_link`'s QR code was too big for the terminal**: `as_ansi` spends
  two columns and one line per module. It is now rendered with half-block
  characters (two module rows per line, one column per module, black on white
  so it stays scannable on dark terminals) at error-correction level `:l`,
  roughly a quarter of the previous area.

## 0.12.4 - 2026-09-17

### Fixed

- **Test suite still printed `Warning: no type cast defined for type
  "regclass"...` on every migrator test** (`test/persistence_migrator_test.rb`):
  `SELECT to_regclass('widgets')` returns a `regclass`-typed column, and
  `lib/monk/persistence/pg.rb`'s `PG::BasicTypeMapForResults` has no
  decoder registered for it, so the `pg` gem warns once per call and falls
  back to the raw string. Added `PersistenceTestHelpers#table_exists?`
  (`test/test_helper.rb`) — the same `information_schema.tables` check
  `Migrator#ensure_schema_migrations_table` and `#drop_table_if_exists`
  already use, which never touches `regclass` at all — and replaced every
  `to_regclass` assertion with it.

## 0.12.3 - 2026-09-17

### Fixed

- **Ctrl+C with no live connections open still printed an unrescued
  `Interrupt` stack trace** (`lib/monk/websocket/server.rb`): 0.12.1 only
  rescued `Ractor::ClosedError` in `Registry#ask`, which guards a
  connection's cleanup racing the registry Ractor's teardown -- a
  different failure point from this one. `Server#run`'s accept loop
  itself never rescued Ctrl+C's default `Interrupt`, raised in whatever
  thread is blocked in `TCPServer#accept` -- unrescued, that's an
  unhandled exception with a backtrace, even though stopping the server
  this way is normal and intended. `#run` now rescues `Interrupt` around
  the loop and closes the `TCPServer`.

## 0.12.2 - 2026-09-17

### Fixed

- **Test suite printed a "method redefined" warning per view per test file**
  (`lib/monk/views.rb`): `Views.method_name_for` deliberately reuses the
  same compiled method name across repeated boots of the same template
  path (so a second `.freeze!` in one process redefines in place rather
  than growing new method names forever), but Ruby warns on every `def`
  that overwrites an existing method unless the old one was explicitly
  removed first. `Views.compile` now calls `Compiled.remove_method` ahead
  of the redefinition it already intends, silencing the warning without
  changing behavior.
- **Test suite printed a Postgres NOTICE ("table ... does not exist,
  skipping") on nearly every test** (`test/test_helper.rb` and the
  persistence/auth/migrator tests): every test's `teardown` already drops
  its own tables, so the *next* test's `DROP TABLE IF EXISTS` setup call
  almost always hits the non-existent case. Added
  `PersistenceTestHelpers#drop_table_if_exists`, which checks
  `information_schema.tables` first and only issues `DROP TABLE` when the
  table is actually there — the same dodge `Migrator#
  ensure_schema_migrations_table` already uses for `CREATE TABLE IF NOT
  EXISTS`'s NOTICE, in the other direction. Replaced every raw `DROP TABLE
  IF EXISTS` in the test suite with it.

## 0.12.1 - 2026-09-17

### Fixed

- **Ctrl+C with live WebSocket connections open printed an unrescued
  `Ractor::ClosedError` stack trace** (`lib/monk/websocket/registry.rb`):
  `Registry#ask` (backing `register`/`unregister`/`broadcast`/`count`)
  sends to the registry's own dedicated Ractor with no guard, unlike
  `Registry#broadcast`'s inner loop, which already rescues
  `Ractor::ClosedError` per-port for the same class of shutdown race
  (with a comment describing exactly this). On SIGINT, Ruby tears down
  Ractors with no defined order; if the registry's Ractor is gone before
  a connection's `Server.serve`-ensure cleanup calls `unsubscribe!` ->
  `unregister` -> `ask`, the send raises unrescued and `report_on_exception`
  prints it. Harmless — the process is already exiting, no message loss
  or leaked state — but noisy. `#ask` now rescues `Ractor::ClosedError`
  and returns `nil`, which every caller here already ignores or only
  reads while the registry is known to be alive.

## 0.12.0 - 2026-09-17

### Added

- **Timestamps on every log line** (`lib/monk/log.rb`, `lib/monk/base.rb`):
  both the per-request access line (`Base#log_request`, to `$stdout` and
  `log/<env>.log`) and the app-level `Monk::Log.debug`/`.info`/`.warn`/
  `.error` lines now lead with a UTC, millisecond-precision ISO 8601 stamp
  (`2026-09-17T14:32:01.123Z GET /hello -> 200 (1.2ms)`,
  `2026-09-17T14:32:01.456Z WARN payment retried`), via a single
  `Monk::Log.timestamp` used by both call sites so the two log lines stay
  in the same format. `Time.now` needs no Ractor-shareability handling —
  it returns a fresh, unshared value on every call — so this added no new
  boot-time freezing concerns.

## 0.11.3 - 2026-09-15

### Fixed

- **`Monk::Log.info`/`debug`/`warn`/`error` raised `Ractor::IsolationError`
  from a worker Ractor** (`lib/monk/log.rb`): the level methods were
  defined via `define_method(&block)`, and a method backed by a Proc
  closure can't be called from a Ractor other than the one that defined
  it — `Environment`'s own comment already warns against exactly this
  pattern (found there first, for `MONK_ENV_VALUES`), but `Log`'s level
  methods didn't follow it. Kino runs each request in a worker Ractor, so
  every call from request-handling code hit this. Replaced with four
  plain `def` methods, same fix as `Environment`. Fixing that surfaced a
  second bug behind it: `Settings::LOG_LEVEL_VALUES` (aliased as
  `Log::LEVELS`, read on every `#enabled?` call) was only shallow-frozen
  via `Array#freeze`, which doesn't freeze the strings inside and so
  isn't Ractor-shareable either — switched to `Ractor.make_shareable`.
  Found via `monk_talk`'s real usage, not by inspection.

## 0.11.2 - 2026-09-15

### Fixed

- **`monk new --postgres`'s generated `.env` was silently never loaded**
  (`lib/monk/scaffold.rb`): `.env`/`.env.test` have shipped with real
  values since 0.11.0, but `dotenv` stayed commented out in the `Gemfile`,
  so `config/settings.rb`'s `require "dotenv/load"` never actually ran —
  `bin/setup_db` and friends fell straight back to
  `config/persistence.rb`'s own `ENV.fetch` defaults instead of the
  app-specific values `.env` was written to provide. `--postgres` now
  uncomments `gem "dotenv"` in the `Gemfile` too. Found the same way as
  0.11.0/0.11.1 — generating a real app and following its own `SETUP.md`,
  not by inspection.
- **`--redis` alone (no `--postgres`) had none of the above** — no `.env`
  at all, so `REDIS_URL` had to be exported by hand for
  `bin/websocket_server`'s fan-out to turn on. `write_env_files!` and the
  `dotenv` fix above now both run whenever `@postgres || @redis`, not just
  `@postgres`; `write_env_files!` only adds the Postgres lines when
  `@postgres` is actually set, and skips writing `.env.test` entirely when
  it would end up empty (true for `--redis` alone, since `REDIS_URL` is
  deliberately never written there anyway — only a test that actually
  exercises `RedisFanout` needs it). `SETUP.md`'s base-skeleton content
  (also covers `--redis`-only apps) now describes the real `.env`/`dotenv`/
  Redis-container setup instead of telling you to export `REDIS_URL`
  inline. Verified end-to-end: a fresh `--redis`-only app's
  `bin/websocket_server` printed `redis fan-out: on` against a real Redis
  with zero manual exports, purely from the generated `.env` + `dotenv`.

## 0.11.1 - 2026-09-15

### Fixed

- **`monk new` now generates `SETUP.md` for every flag combination, not
  just `--postgres`** (`lib/monk/scaffold.rb`, `exe/monk`): 0.11.0's
  `SETUP.md` generation was gated behind `@postgres`, so the base skeleton
  and `--redis`-only apps got no setup instructions at all, despite both
  still having a real first dev step (`bin/server`) and an unscaffolded
  test framework to wire up. `setup_md_content` now branches on
  `@postgres` between the existing Postgres-oriented walkthrough and a new
  lightweight one for base/`--redis`-only apps — no database/container/
  migration steps, and a Minitest smoke test against `Monk::Settings`
  instead of `Persistence::Pg`, since `config.ru`'s `class App` lives
  inline in a rackup file with nothing else standalone-requirable to test
  yet.
- **README Quick Start's `bundle exec rake test` line**: a plain
  `monk new my_app` (no flags) has never scaffolded a `Rakefile` or
  `test/` directory, so that command has been broken since it was first
  written (#36) — unrelated to the `SETUP.md` fix above, but caught and
  fixed alongside it.

## 0.11.0 - 2026-09-15

### Added

- **`monk new --postgres` now wires the generated app together instead of
  just dropping files next to each other** (`lib/monk/scaffold.rb`,
  `exe/monk`): previously `config.ru` never required `config/persistence.rb`
  or `config/auth.rb` at all, so a freshly scaffolded HTTP process never
  actually registered a database connection unless you edited `config.ru`
  by hand.
  - `config.ru` now gets `require_relative "config/persistence"` (or
    `"config/auth"` under `--auth` — `config/auth.rb` itself
    `require_relative`s `persistence`) appended right after the settings
    require, before `class App`.
  - `.env`, `.env.test`, and a tracked `.env.example` are generated with
    `DB_NAME` derived from the target directory name
    (`APP_NAME_development`/`APP_NAME_test`), instead of relying on the
    generic `app_development` fallback baked into `config/persistence.rb`'s
    own `ENV.fetch` — every scaffolded app used to default to that same
    literal name, risking collisions between separate local apps sharing
    one Postgres instance. `--auth` adds a placeholder `AUTH_SECRET` to all
    three files; `--redis` adds a placeholder `REDIS_URL` to `.env`/
    `.env.example` only, deliberately not `.env.test` — only a test that
    actually exercises `RedisFanout` needs it.
  - A generated `SETUP.md`, tailored to the exact flags passed, walks
    through dev setup (reusing or starting Postgres/Redis containers,
    creating the database, running migrations, booting `bin/server`/
    `bin/websocket_server`) and then test setup, including the minimum
    Minitest wiring (`test/test_helper.rb`, a `Rakefile`, one real smoke
    test) since `monk new` still scaffolds no test framework itself.

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
