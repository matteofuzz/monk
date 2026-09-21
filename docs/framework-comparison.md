# Monk vs. Sinatra vs. Rails

Complexity and weight comparison, based on the codebase as of v0.13.0 (including `Monk::Live`).

## Footprint

- **Monk**: 4,186 lines of Ruby across 42 files in `lib/monk` (excluding the
  `monk new` scaffold templates) — routing, context, ERB views/layouts,
  a boot-time static-asset manifest, settings/env tiers, auth
  (sessions/tokens/cookies/CSRF/rate-limiting), Postgres persistence + model +
  migrator, a full WebSocket stack (handshake, frames, connection
  registry, server, Redis fan-out for cross-process broadcast), and
  `Monk::Live` (~500 lines of Ruby plus ~300 lines of browser JS and a
  vendored, minified idiomorph) for server-rendered live page updates.
  Runtime dependencies: `rack` and `base64` only; `pg`, `redis`, and `kino`
  are dev-only. 7,518 lines of tests.
- **Sinatra**: core is comparable in size (~2,000 lines), but ships as a
  thin routing DSL only — everything else (sessions/CSRF protection,
  persistence, websockets, live updates) is a separate gem you add yourself.
- **Rails**: hundreds of thousands of lines across railties, Action Pack,
  Active Record, Active Support, Action View, Action Cable, Active Job,
  Active Storage, Action Text, Action Mailbox, etc. Its live-update story
  (Action Cable + Turbo Streams, from `turbo-rails`) is itself a
  multi-thousand-line stack plus a JS bundle.

### Monk breakdown by module

Ruby LOC in `lib/monk` (scaffold templates excluded) and the Ruby test LOC
that covers each module.

| Module | Files | LOC | Test LOC | What it holds |
|---|---|---|---|---|
| Core | 10 | 891 | 1,559 (core + shared helpers) | `Monk::Base` routing/dispatch (323), settings (151), logging (130), context, environment, errors, `StateRactor`, freeze hooks |
| WebSocket | 8 | 831 | 1,411 | handshake, frames, connection (226), server (234), registry, Redis fan-out |
| Persistence | 7 | 597 | 817 | Postgres model (233), migrator (165), connection/boot layer |
| Scaffold (`monk new`) | 1 | 594 | 589 (incl. `exe/monk`) | generator for base/auth/postgres/redis/live apps |
| Live | 8 | 495 | 1,688 | publisher, session, policy, renderer, envelope, `live_topic` helper |
| Auth | 6 | 406 | 922 | sessions, tokens, cookies, CSRF, rate limiter, helpers |
| Assets | 1 | 197 | 206 | boot-time static-asset manifest |
| Views | 1 | 175 | 326 | ERB views/layouts/partials |
| **Total** | **42** | **4,186** | **7,518** | |

Not counted above: the Live browser runtime (`monk_live.js` 204,
`protocol.js` 87, vendored minified idiomorph) and the JS tests under
`test/js`.

Live has the highest test-to-code ratio (about 3.4:1) because it is covered
by real-browser and multi-process tests. The scaffold is the largest single
file (594) but is tooling, not runtime.

## Side by side

| | Sinatra | Monk | Rails |
|---|---|---|---|
| Core LOC | ~2,000 (comparable) | ~4,200 (+ ~300 JS) | hundreds of thousands across railties/AP/AR/AS/etc. |
| Runtime deps | rack, rack-protection, tilt, mustermann | rack, base64 | ~10 first-party gems, each with their own tree (~30+ total) |
| Feature scope | routing + DSL only — everything else is a gem you bolt on | routing, views/layouts, static assets, settings/env, auth, Postgres ORM + migrator, websockets incl. Redis fan-out, live HTML patching — all built-in and opinionated (ERB only, Postgres only, one auth scheme) | routing, ORM (multi-DB), views (multi-engine), jobs, mailers, cable, storage, text, i18n, asset pipeline — pluggable at every layer |
| Concurrency model | none prescribed — thread-safety is your problem | Ractor-safety is load-bearing: routes/handlers are statically checked to be `Ractor.shareable?` at boot | threads/processes; no Ractor-native design |
| Live page updates | none — bring your own websocket gem and client JS | `Monk::Live`: render a partial once, push it to topic subscribers, client morphs it in; deny-by-default subscribe rules; resync by refetch. Server → client only | Action Cable + Turbo Streams (`turbo-rails`): broadcast partials, plus client → server channels, presence-style patterns, and pluggable adapters |
| "Magic" | almost none — DSL is thin, behavior is traceable | almost none — explicit `Context`, explicit boot/freeze step, explicit `StateRactor` for shared mutable state | heavy convention-over-configuration (autoloading, callbacks, concerns, generators) — powerful but harder to trace |

## Takeaways

Monk carries meaningfully more feature scope than Sinatra ships with while
staying more than an order of magnitude under Rails, achieved by narrowing choices
rather than adding abstraction: one template engine, one database, one auth
pattern, one server-concurrency model. That's the opposite of Rails'
strategy (breadth via pluggability), which is why Monk stays around 4,200
lines of Ruby while doing things Sinatra needs `sinatra-contrib` + `warden` +
`sequel`/`activerecord` + `faye-websocket` (plus a hand-rolled Redis
fan-out for cross-process broadcast, and your own DOM-patching client) to
match.

`Monk::Live` is the closest Monk gets to a Rails feature by design: it
covers the Turbo Streams use case (server-owned state changes, every tab
updates) using the views the app already has. It is deliberately narrower:
server → client only (no `onclick`/forms over the socket), no presence, no
replay of missed messages (a resync refetches the page), no per-viewer
diffing, and subscription rules are checked only at subscribe time. It also
needs two processes plus Redis, because `Monk::WebSocket` cannot share a
process with Kino. Rails' Action Cable runs in-process with the app and
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
