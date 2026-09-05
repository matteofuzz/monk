# Changelog

All notable changes to this project are documented here. Format is loosely
[Keep a Changelog](https://keepachangelog.com/); versions are as released
in `lib/monk/version.rb`.

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
