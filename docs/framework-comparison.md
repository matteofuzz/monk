# Monk vs. Sinatra vs. Rails

Complexity and weight comparison, based on the codebase after v0.17.0: the unreleased `main_dev/monk_jobs` branch as of 2026-09-29, which adds `Monk::Jobs` (background jobs on Postgres), `Monk::Mail.deliver_later` and `monk new --jobs`. LOC is `wc -l` of every `.rb` file under `lib/` except the `monk new` templates, and test LOC is `wc -l` of every `.rb` file under `test/`, the same method as earlier versions of this page.

## Footprint

- **Monk**: 6,506 lines of Ruby across 59 files (`lib/monk.rb` plus `lib/monk`, excluding the
  `monk new` scaffold templates) — routing, context, ERB views/layouts,
  a boot-time static-asset manifest, settings/env tiers, auth
  (sessions/tokens/cookies/CSRF/rate-limiting), Postgres persistence + model +
  migrator, a full WebSocket stack (handshake, frames, connection
  registry, server, and cross-process broadcast fan-out over either Redis
  pub/sub or Postgres `LISTEN`/`NOTIFY`), email (`Monk::Mail`: its own MIME
  builder plus SMTP and log transports, sent inline or from a job),
  background jobs (`Monk::Jobs`: a Postgres queue and a job process running
  worker Ractors), and
  `Monk::Live` (~500 lines of Ruby plus ~300 lines of browser JS and a
  vendored, minified idiomorph) for server-rendered live page updates.
  Runtime dependencies: `rack` and `base64` only; `pg`, `redis`, `rqrcode` and
  `net-smtp` are opt-in per app (dev-only for Monk itself), and `kino` is only in the
  repo's `Gemfile` for the demo app. 12,170 lines of tests.
- **Sinatra**: core is comparable in size (~2,000 lines), but ships as a
  thin routing DSL only — everything else (sessions/CSRF protection,
  persistence, websockets, live updates, email, background jobs) is a
  separate gem you add yourself.
- **Rails**: hundreds of thousands of lines across railties, Action Pack,
  Active Record, Active Support, Action View, Action Cable, Active Job,
  Active Storage, Action Text, Action Mailbox, etc. Its live-update story
  (Action Cable + Turbo Streams, from `turbo-rails`) is itself a
  multi-thousand-line stack plus a JS bundle, and since Rails 8 its default
  job backend, Solid Queue, is a separate database-backed gem on top of
  Active Job.

### Monk breakdown by module

Ruby LOC in `lib/monk.rb` + `lib/monk` (scaffold templates excluded) and the Ruby test LOC
that covers each module.

| Module | Files | LOC | Test LOC | What it holds |
|---|---|---|---|---|
| Jobs | 8 | 1,030 | 1,823 (incl. child job processes) | Postgres adapter (272), runtime/supervisor (239), configure/enqueue/registry/`drain!` (229), `Monk::Job` and its settings (117), worker loop (94), argument check (43), errors, claim value |
| WebSocket | 9 | 1,012 | 1,595 | handshake, frames, connection (226), server (234), registry, Redis fan-out (103), Postgres fan-out (174) |
| Scaffold (`monk new`) | 1 | 986 | 1,397 (incl. `exe/monk`) | generator for base/auth/mail/postgres/redis/live/jobs apps, Dockerfile, the resolved-flags summary |
| Core | 10 | 894 | 1,596 (core + shared helpers) | `Monk::Base` routing/dispatch (323), settings (151), logging (130), context, environment, errors, `StateRactor`, freeze hooks |
| Mail | 8 | 631 | 1,320 (incl. a fake SMTP server) | MIME builder (124), configure/deliver/render (121), SMTP and log transports (115), `MAIL_URL` parsing (76), message value (66), `deliver_later` and its job (53), address handling (41) |
| Persistence | 7 | 617 | 875 | Postgres model (233), migrator (165), connection/boot layer incl. a `json`/`jsonb` decoder |
| Live | 8 | 495 | 1,940 | publisher, session, policy, renderer, envelope, `live_topic` helper |
| Auth | 6 | 458 | 1,065 | sessions, tokens, cookies, CSRF, rate limiter, link delivery, helpers |
| Assets | 1 | 197 | 206 | boot-time static-asset manifest |
| Views | 1 | 186 | 353 | ERB views/layouts/partials |
| **Total** | **59** | **6,506** | **12,170** | |

Not counted above: the Live browser runtime (`monk_live.js` 204,
`protocol.js` 87, vendored minified idiomorph) and the JS tests under
`test/js`.

Live has the highest test-to-code ratio (about 3.9:1) because it is covered
by real-browser and multi-process tests, run against both fan-out
transports. Jobs is now the largest module, just ahead of WebSocket. Most of
it is the Postgres adapter's SQL (one statement per operation, so a job's
state never needs a multi-statement transaction) and the supervisor's
crash recovery: respawning dead worker Ractors, releasing the job a dead
worker held, and reconnecting after a database restart. Its tests (about
1.8:1) run real child job processes, stopped with `TERM` and `kill -9`,
and kill their database connections mid-run. The scaffold is the largest
single file (986) but is tooling, not runtime. Mail is about 2:1: every
SMTP test sends from a real worker Ractor to a fake SMTP server, over plain
connections, STARTTLS and implicit TLS.

## Side by side

| | Sinatra | Monk | Rails |
|---|---|---|---|
| Core LOC | ~2,000 (comparable) | ~6,500 (+ ~300 JS) | hundreds of thousands across railties/AP/AR/AS/etc. |
| Runtime deps | rack, rack-protection, tilt, mustermann | rack, base64 | ~10 first-party gems, each with their own tree (~30+ total) |
| Feature scope | routing + DSL only — everything else is a gem you bolt on | routing, views/layouts, static assets, settings/env, auth, Postgres ORM + migrator, websockets incl. Redis or Postgres fan-out, live HTML patching, text/HTML email over SMTP, background jobs on Postgres — all built-in and opinionated (ERB only, Postgres only, one auth scheme) | routing, ORM (multi-DB), views (multi-engine), jobs, mailers, cable, storage, text, i18n, asset pipeline — pluggable at every layer |
| Concurrency model | none prescribed — thread-safety is your problem | Ractor-safety is load-bearing: routes/handlers are statically checked to be `Ractor.shareable?` at boot | threads/processes; no Ractor-native design |
| Live page updates | none — bring your own websocket gem and client JS | `Monk::Live`: render a partial once, push it to topic subscribers, client morphs it in; deny-by-default subscribe rules; resync by refetch. Server → client only | Action Cable + Turbo Streams (`turbo-rails`): broadcast partials, plus client → server channels, presence-style patterns, and pluggable adapters |
| Email | none — bring the `mail` gem (or `pony`) and configure it yourself | `Monk::Mail`: text and/or HTML (from a view), MIME built by Monk, one `MAIL_URL` (any provider's SMTP relay or a local one), sent from the worker Ractor, or from the job process with `deliver_later`. No attachments, no previews | Action Mailer: mailer classes and views, attachments, previews, interceptors, `deliver_later` via Active Job, pluggable delivery methods |
| Background jobs | none — bring Sidekiq (and Redis) or a database-backed queue gem | `Monk::Jobs`: a Postgres-only queue (a narrow state table plus a payload table, `SKIP LOCKED`) and a job process, `bin/jobs`, running worker Ractors. Retries with backoff, scheduled jobs, `never_retry`, enqueue inside the app's own transaction, `drain!` for tests; at-least-once. No recurring jobs, concurrency limits, pausing, batches or dashboard | Active Job with a pluggable backend; since Rails 8 Solid Queue (database-backed) by default, with recurring tasks, concurrency controls, pausing, and a dashboard (Mission Control, a separate gem) |
| "Magic" | almost none — DSL is thin, behavior is traceable | almost none — explicit `Context`, explicit boot/freeze step, explicit `StateRactor` for shared mutable state | heavy convention-over-configuration (autoloading, callbacks, concerns, generators) — powerful but harder to trace |

## Takeaways

Monk carries meaningfully more feature scope than Sinatra ships with while
staying more than an order of magnitude under Rails, achieved by narrowing choices
rather than adding abstraction: one template engine, one database, one auth
pattern, one server-concurrency model. That's the opposite of Rails'
strategy (breadth via pluggability), which is why Monk stays around 6,500
lines of Ruby while doing things Sinatra needs `sinatra-contrib` + `warden` +
`sequel`/`activerecord` + `faye-websocket` + `mail` + `sidekiq` (and Redis)
(plus a hand-rolled Redis or Postgres fan-out for cross-process broadcast,
and your own DOM-patching client) to match.

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

`Monk::Mail` exists for a Ractor reason, not a scope one: the `mail` gem,
and so Action Mailer, raises `Ractor::IsolationError` as soon as a message is
built in a worker Ractor (class variables and a `Singleton` config), so a
Monk app can't bring the usual mailer. It covers what an app actually sends
(magic links, notifications) in about 630 lines and is much narrower than
Action Mailer: no attachments, no previews. `deliver` blocks the worker for
its duration (ADR 0012), while `deliver_later` sends from the job process,
retrying only failures that can succeed later. One thing it does that
Action Mailer's `deliver_later` wouldn't: `monk new --auth --jobs` creates
a login token inside the job that sends it, so the raw token is never
written to the queue, keeping `Monk::Auth`'s "only hashes in the database"
guarantee (ADR 0014).

`Monk::Jobs` exists for much the same reason. No Ruby job library is
Ractor-aware, and the database-backed ones build on Active Record, which
fails in a worker Ractor just as Sequel did (ADR 0013). It is a
Postgres-only queue, run by `bin/jobs` on worker Ractors, so jobs run in
parallel within one process rather than taking turns on one interpreter
lock as threads do. Its table layout was chosen by benchmarking it against
Solid Queue's multi-table split and a single wide table (ADR 0013,
`docs/history/plan-jobs.md` Phase 0). It is much narrower than Active Job
with Solid Queue: no recurring jobs, no concurrency limits, no pausing, no
batches, no dashboard, one backend. Delivery is at-least-once, so jobs must
be safe to repeat.

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
