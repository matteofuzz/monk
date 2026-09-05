# Monk vs. Sinatra vs. Rails

Complexity and weight comparison, based on the codebase as of v0.7.0.

## Footprint

- **Monk**: 2,140 lines across 40 files in `lib/` — routing, context, ERB
  views, static assets, auth (sessions/tokens/cookies/rate-limiting),
  Postgres persistence + migrator, and a full WebSocket stack (handshake,
  frames, connection registry, server). Runtime dependencies: `rack` and
  `base64` only; `pg` and `kino` are dev-only. 4,319 lines of tests.
- **Sinatra**: core is comparable in size (~2,000 lines), but ships as a
  thin routing DSL only — everything else (sessions/CSRF protection,
  persistence, websockets) is a separate gem you add yourself.
- **Rails**: hundreds of thousands of lines across railties, Action Pack,
  Active Record, Active Support, Action View, Action Cable, Active Job,
  Active Storage, Action Text, Action Mailbox, etc.

## Side by side

| | Sinatra | Monk | Rails |
|---|---|---|---|
| Core LOC | ~2,000 (comparable) | ~2,100 | hundreds of thousands across railties/AP/AR/AS/etc. |
| Runtime deps | rack, rack-protection, tilt, mustermann | rack, base64 | ~10 first-party gems, each with their own tree (~30+ total) |
| Feature scope | routing + DSL only — everything else is a gem you bolt on | routing, views, auth, Postgres ORM, websockets, all built-in and opinionated (ERB only, Postgres only, one auth scheme) | routing, ORM (multi-DB), views (multi-engine), jobs, mailers, cable, storage, text, i18n, asset pipeline — pluggable at every layer |
| Concurrency model | none prescribed — thread-safety is your problem | Ractor-safety is load-bearing: routes/handlers are statically checked to be `Ractor.shareable?` at boot | threads/processes; no Ractor-native design |
| "Magic" | almost none — DSL is thin, behavior is traceable | almost none — explicit `Context`, explicit boot/freeze step, explicit `StateRactor` for shared mutable state | heavy convention-over-configuration (autoloading, callbacks, concerns, generators) — powerful but harder to trace |

## Takeaways

Monk reads as Sinatra-sized code carrying more feature scope than Sinatra
ships with, achieved by narrowing choices rather than adding abstraction:
one template engine, one database, one auth pattern, one server-concurrency
model. That's the opposite of Rails' strategy (breadth via pluggability),
which is why Monk stays under 2,200 lines while doing things Sinatra needs
`sinatra-contrib` + `warden` + `sequel`/`activerecord` + `faye-websocket` to
match.

The one place Monk carries complexity neither of the others has: the
Ractor-shareability guarantees (`.freeze!`, `UnshareableRouteError`,
`StateRactor`). That's real conceptual weight — a constraint Sinatra and
Rails users never have to think about — but it's the framework's actual
reason to exist, not incidental bloat.

Note: `rack-protection` (Sinatra's default CSRF/clickjacking/XSS-header
middleware suite) has no equivalent in Monk today. Monk's `auth` module
covers sessions/tokens/cookies/rate-limiting, but a generic CSRF-token or
security-header middleware is currently a gap — fillable by requiring
`rack-protection` directly, since Monk apps are plain Rack underneath.

**Bottom line**: closer to Sinatra than Rails in weight and boot cost
(small dependency graph, no autoloading, no framework-managed process
boundary), but not really "Sinatra-style" in scope — it's a
batteries-included micro-framework where the batteries are deliberately
non-swappable. Rails is a different category entirely: comparing LOC is
almost apples-to-oranges given Rails' pluggable-everything architecture.
