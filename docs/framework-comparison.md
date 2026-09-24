# Monk vs. Sinatra vs. Rails

Complexity and weight comparison, based on the codebase as of v0.16.0 (LOC recomputed for this version: it now includes v0.14.0's deploy support and v0.16.0's `Monk::WebSocket::PgFanout`).

## Footprint

- **Monk**: 4,527 lines of Ruby across 43 files (`lib/monk.rb` plus `lib/monk`, excluding the
  `monk new` scaffold templates) — routing, context, ERB views/layouts,
  a boot-time static-asset manifest, settings/env tiers, auth
  (sessions/tokens/cookies/CSRF/rate-limiting), Postgres persistence + model +
  migrator, a full WebSocket stack (handshake, frames, connection
  registry, server, and cross-process broadcast fan-out over either Redis
  pub/sub or Postgres `LISTEN`/`NOTIFY`), and
  `Monk::Live` (~500 lines of Ruby plus ~300 lines of browser JS and a
  vendored, minified idiomorph) for server-rendered live page updates.
  Runtime dependencies: `rack` and `base64` only; `pg`, `redis`, and `rqrcode`
  are opt-in per app (dev-only for Monk itself), and `kino` is only in the
  repo's `Gemfile` for the demo app. 8,268 lines of tests.
- **Sinatra**: core is comparable in size (~2,000 lines), but ships as a
  thin routing DSL only — everything else (sessions/CSRF protection,
  persistence, websockets, live updates) is a separate gem you add yourself.
- **Rails**: hundreds of thousands of lines across railties, Action Pack,
  Active Record, Active Support, Action View, Action Cable, Active Job,
  Active Storage, Action Text, Action Mailbox, etc. Its live-update story
  (Action Cable + Turbo Streams, from `turbo-rails`) is itself a
  multi-thousand-line stack plus a JS bundle.

### Monk breakdown by module

Ruby LOC in `lib/monk.rb` + `lib/monk` (scaffold templates excluded) and the Ruby test LOC
that covers each module.

| Module | Files | LOC | Test LOC | What it holds |
|---|---|---|---|---|
| WebSocket | 9 | 1,012 | 1,595 | handshake, frames, connection (226), server (234), registry, Redis fan-out (103), Postgres fan-out (174) |
| Core | 10 | 894 | 1,559 (core + shared helpers) | `Monk::Base` routing/dispatch (323), settings (151), logging (130), context, environment, errors, `StateRactor`, freeze hooks |
| Scaffold (`monk new`) | 1 | 688 | 733 (incl. `exe/monk`) | generator for base/auth/postgres/redis/live apps, Dockerfile |
| Persistence | 7 | 597 | 817 | Postgres model (233), migrator (165), connection/boot layer |
| Live | 8 | 495 | 1,940 | publisher, session, policy, renderer, envelope, `live_topic` helper |
| Auth | 6 | 458 | 1,065 | sessions, tokens, cookies, CSRF, rate limiter, link delivery, helpers |
| Assets | 1 | 197 | 206 | boot-time static-asset manifest |
| Views | 1 | 186 | 353 | ERB views/layouts/partials |
| **Total** | **43** | **4,527** | **8,268** | |

Not counted above: the Live browser runtime (`monk_live.js` 204,
`protocol.js` 87, vendored minified idiomorph) and the JS tests under
`test/js`.

Live has the highest test-to-code ratio (about 3.9:1) because it is covered
by real-browser and multi-process tests, now run against both fan-out
transports. WebSocket overtook Core as the largest module with `PgFanout`;
its subscriber loop is the one place the two transports genuinely differ
(a dedicated `LISTEN` connection, echo suppression, an ~8KB payload cap).
The scaffold is the largest single file (688) but is tooling, not runtime.

## Side by side

| | Sinatra | Monk | Rails |
|---|---|---|---|
| Core LOC | ~2,000 (comparable) | ~4,500 (+ ~300 JS) | hundreds of thousands across railties/AP/AR/AS/etc. |
| Runtime deps | rack, rack-protection, tilt, mustermann | rack, base64 | ~10 first-party gems, each with their own tree (~30+ total) |
| Feature scope | routing + DSL only — everything else is a gem you bolt on | routing, views/layouts, static assets, settings/env, auth, Postgres ORM + migrator, websockets incl. Redis or Postgres fan-out, live HTML patching — all built-in and opinionated (ERB only, Postgres only, one auth scheme) | routing, ORM (multi-DB), views (multi-engine), jobs, mailers, cable, storage, text, i18n, asset pipeline — pluggable at every layer |
| Concurrency model | none prescribed — thread-safety is your problem | Ractor-safety is load-bearing: routes/handlers are statically checked to be `Ractor.shareable?` at boot | threads/processes; no Ractor-native design |
| Live page updates | none — bring your own websocket gem and client JS | `Monk::Live`: render a partial once, push it to topic subscribers, client morphs it in; deny-by-default subscribe rules; resync by refetch. Server → client only | Action Cable + Turbo Streams (`turbo-rails`): broadcast partials, plus client → server channels, presence-style patterns, and pluggable adapters |
| "Magic" | almost none — DSL is thin, behavior is traceable | almost none — explicit `Context`, explicit boot/freeze step, explicit `StateRactor` for shared mutable state | heavy convention-over-configuration (autoloading, callbacks, concerns, generators) — powerful but harder to trace |

## Takeaways

Monk carries meaningfully more feature scope than Sinatra ships with while
staying more than an order of magnitude under Rails, achieved by narrowing choices
rather than adding abstraction: one template engine, one database, one auth
pattern, one server-concurrency model. That's the opposite of Rails'
strategy (breadth via pluggability), which is why Monk stays around 4,500
lines of Ruby while doing things Sinatra needs `sinatra-contrib` + `warden` +
`sequel`/`activerecord` + `faye-websocket` (plus a hand-rolled Redis or
Postgres fan-out for cross-process broadcast, and your own DOM-patching
client) to match.

`Monk::Live` is the closest Monk gets to a Rails feature by design: it
covers the Turbo Streams use case (server-owned state changes, every tab
updates) using the views the app already has. It is deliberately narrower:
server → client only (no `onclick`/forms over the socket), no presence, no
replay of missed messages (a resync refetches the page), no per-viewer
diffing, and subscription rules are checked only at subscribe time. It also
needs two processes plus a cross-process transport, because
`Monk::WebSocket` cannot share a process with Kino. That transport is Redis,
or — for an app that already runs Postgres — `PgFanout` over
`LISTEN`/`NOTIFY` (`monk new --live --postgres`), which drops Redis entirely
at the cost of a ~8KB per-broadcast cap and no story for many WS processes.
The trade mirrors Action Cable's own Redis vs. PostgreSQL adapters (same
`NOTIFY` limit). Rails' Action Cable runs in-process with the app and
supports more adapters, at a much higher weight.

The one place Monk carries complexity neither of the others has: the
Ractor-shareability guarantees (`.freeze!`, `UnshareableRouteError`,
`StateRactor`). That's real conceptual weight — a constraint Sinatra and
Rails users never have to think about — but it's the framework's actual
reason to exist, not incidental bloat.

Note: `rack-protection` (Sinatra's default clickjacking/XSS-header
middleware suite) has no full equivalent in Monk today. Monk's `auth` module
covers sessions/tokens/cookies/rate-limiting and a stateless double-submit
CSRF token (`require_csrf!`, cookie-authenticated requests only), but generic
security-header middleware is currently a gap — fillable by requiring
`rack-protection` directly, since Monk apps are plain Rack underneath.

**Bottom line**: closer to Sinatra than Rails in weight and boot cost
(small dependency graph, no autoloading, no framework-managed process
boundary), but not really "Sinatra-style" in scope — it's a
batteries-included micro-framework where the batteries are deliberately
non-swappable. Rails is a different category entirely: comparing LOC is
almost apples-to-oranges given Rails' pluggable-everything architecture.
