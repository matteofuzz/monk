# Monk vs. Sinatra vs. Rails

Complexity and weight comparison, based on the codebase at v0.21.0 (LOC recomputed for this version, which brings scaffolding by module: `monk new` makes the core app and `monk add` adds each module to any app, through one generator per module, a CLI with `--json` output, and the `bin/` scripts' error explanations; the framework gains `Monk::Auth.login_link`, `SendLoginLink` and `log_out!`, `monk_head` and module assets served from the gem). LOC is `wc -l` of every `.rb` file under `lib/` except the scaffold templates, and test LOC is `wc -l` of every `.rb` file under `test/`, the same method as earlier versions of this page.

## Footprint

- **Monk**: 8,567 lines of Ruby across 77 files (`lib/monk.rb` plus `lib/monk`, excluding the
  scaffold templates) — routing, context, ERB views/layouts,
  a boot-time static-asset manifest, settings/env tiers, auth
  (sessions/tokens/cookies/CSRF/rate-limiting), Postgres persistence + model +
  migrator + connection pools for Ractors, a full WebSocket stack (handshake, frames, connection
  registry, server, and cross-process broadcast fan-out over either Redis
  pub/sub or Postgres `LISTEN`/`NOTIFY`), email (`Monk::Mail`: its own MIME
  builder plus SMTP and log transports, sent inline or from a job),
  background jobs (`Monk::Jobs`: a Postgres queue and a job process running
  worker Ractors), and
  `Monk::Live` (~570 lines of Ruby plus ~300 lines of browser JS and a
  vendored, minified idiomorph) for server-rendered live page updates, and
  the scaffolding that writes an app and adds each of these to it
  (`monk new`, `monk add`).
  Runtime dependencies: `rack` and `base64` only; `pg`, `redis`, `rqrcode`,
  `net-smtp` and `dotenv` are opt-in per app (dev-only for Monk itself), and `kino` is only in the
  repo's `Gemfile` for the demo app. 15,365 lines of tests.
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
| Scaffolding (`monk new`, `monk add`) | 15 | 1,506 | 2,088 (incl. `exe/monk`) | the generator engine: plan every module and option, check every file, then write (449); its result as text, JSON and an exit code (279); the CLI (277); the module DSL (153); the `bin/` scripts' error explanations (107); one generator of ~20 lines per module |
| WebSocket | 10 | 1,472 | 2,385 | handshake, frames, connection, server incl. `authenticate: :optional`, `db_pool:` and stop on `TERM`, registry incl. `close_all`, Redis fan-out, Postgres fan-out incl. pooled publishing, listeners that reconnect, a socket's connections closed when it ends |
| Persistence | 8 | 1,442 | 1,684 | connection pools for Ractors (513: dispatcher, workers, errors that keep their class across Ractors), registry and checkout with the dropped-connection probe and pool lifecycle, Postgres model, migrator, Postgres backend incl. a `json`/`jsonb` decoder |
| Jobs | 8 | 1,039 | 1,824 (incl. child job processes) | Postgres adapter (274), runtime/supervisor (239), configure/enqueue/registry/`drain!`, `Monk::Job` and its settings, worker loop, argument check, errors, claim value |
| Core | 10 | 944 | 1,961 (core + shared helpers) | `Monk::Base` routing/dispatch (343), settings (151), logging (130), context incl. `monk_head`, environment, errors, `StateRactor`, freeze hooks |
| Mail | 9 | 641 | 1,320 (incl. a fake SMTP server) | MIME builder, configure/deliver/render, SMTP and log transports, `MAIL_URL` parsing, message value, `deliver_later` and its job (loaded with jobs), address handling |
| Live | 8 | 573 | 2,191 | publisher, session, policy incl. pooled rules, renderer, envelope, `live_topic` and its `<head>` tags, `listen!`, the client served from the gem |
| Auth | 7 | 537 | 1,266 | sessions, tokens, cookies, CSRF, rate limiter, link delivery and `login_link`, `SendLoginLink`, helpers incl. `log_out!` |
| Assets | 1 | 227 | 293 | boot-time static-asset manifest, plus modules' own files mounted under `/_monk/` |
| Views | 1 | 186 | 353 | ERB views/layouts/partials |
| **Total** | **77** | **8,567** | **15,365** | |

Not counted above: the Live browser runtime (`monk_live.js` 204,
`protocol.js` 92, vendored minified idiomorph) and the JS tests under
`test/js`.

Live has the highest test-to-code ratio (about 4:1) because it is covered
by real-browser and multi-process tests, run against both fan-out
transports. Scaffolding is now the largest module, but it is tooling, not
runtime: no app loads it. Its tests generate real apps and run their own
suites, uncomment every example and exercise it (a real socket for the
chat example), check that every pair of modules gives the same app in
either order, and (with `SLOW=1`) run all 128 module combinations.
Persistence and WebSocket come next: 0.20 added connection pools (a dispatcher Ractor and worker Ractors that
own the connections, since a connection can't move between Ractors) and
recovery from a dropped connection. WebSocket grew with it: both fanouts'
listeners now reconnect and make open pages resync, and the server can
check sessions through a pool. Most of Jobs is the Postgres adapter's SQL (one statement per operation, so a job's
state never needs a multi-statement transaction) and the supervisor's
crash recovery: respawning dead worker Ractors, releasing the job a dead
worker held, and reconnecting after a database restart. Its tests (about
1.8:1) run real child job processes, stopped with `TERM` and `kill -9`,
and kill their database connections mid-run. Mail is about 2:1: every
SMTP test sends from a real worker Ractor to a fake SMTP server, over plain
connections, STARTTLS and implicit TLS.

## Side by side

| | Sinatra | Monk | Rails |
|---|---|---|---|
| Core LOC | ~2,000 (comparable) | ~8,600 (+ ~300 JS) | hundreds of thousands across railties/AP/AR/AS/etc. |
| Runtime deps | rack, rack-protection, tilt, mustermann | rack, base64 | ~10 first-party gems, each with their own tree (~30+ total) |
| Feature scope | routing + DSL only — everything else is a gem you bolt on | routing, views/layouts, static assets, settings/env, auth, Postgres ORM + migrator, websockets incl. Redis or Postgres fan-out, live HTML patching, text/HTML email over SMTP, background jobs on Postgres — all built-in and opinionated (ERB only, Postgres only, one auth scheme) | routing, ORM (multi-DB), views (multi-engine), jobs, mailers, cable, storage, text, i18n, asset pipeline — pluggable at every layer |
| Concurrency model | none prescribed — thread-safety is your problem | Ractor-safety is load-bearing: routes/handlers are statically checked to be `Ractor.shareable?` at boot | threads/processes; no Ractor-native design |
| Live page updates | none — bring your own websocket gem and client JS | `Monk::Live`: render a partial once, push it to topic subscribers, client morphs it in; deny-by-default subscribe rules; resync by refetch. Server → client only | Action Cable + Turbo Streams (`turbo-rails`): broadcast partials, plus client → server channels, presence-style patterns, and pluggable adapters |
| Email | none — bring the `mail` gem (or `pony`) and configure it yourself | `Monk::Mail`: text and/or HTML (from a view), MIME built by Monk, one `MAIL_URL` (any provider's SMTP relay or a local one), sent from the worker Ractor, or from the job process with `deliver_later`. No attachments, no previews | Action Mailer: mailer classes and views, attachments, previews, interceptors, `deliver_later` via Active Job, pluggable delivery methods |
| Background jobs | none — bring Sidekiq (and Redis) or a database-backed queue gem | `Monk::Jobs`: a Postgres-only queue (a narrow state table plus a payload table, `SKIP LOCKED`) and a job process, `bin/jobs`, running worker Ractors. Retries with backoff, scheduled jobs, `never_retry`, enqueue inside the app's own transaction, `drain!` for tests; at-least-once. No recurring jobs, concurrency limits, pausing, batches or dashboard | Active Job with a pluggable backend; since Rails 8 Solid Queue (database-backed) by default, with recurring tasks, concurrency controls, pausing, and a dashboard (Mission Control, a separate gem) |
| Scaffolding | none built in | `monk new` makes the core app, `monk add <module>` adds a module to any app, new or old: one generator per module, which only creates files and appends lines, adding its dependencies first. Each brings its wiring, commented examples of how to use it (tested by Monk), a test in the app, and `SETUP.md`/`AGENTS.md` sections; `--json` and exit codes for agents | `rails new` with its options, then `bin/rails generate` (resources, `authentication`) and install tasks (`solid_queue:install`, ...) that edit existing files; app templates for recipes |
| "Magic" | almost none — DSL is thin, behavior is traceable | almost none — explicit `Context`, explicit boot/freeze step, explicit `StateRactor` for shared mutable state | heavy convention-over-configuration (autoloading, callbacks, concerns, generators) — powerful but harder to trace |

## Takeaways

Monk carries meaningfully more feature scope than Sinatra ships with while
staying more than an order of magnitude under Rails, achieved by narrowing choices
rather than adding abstraction: one template engine, one database, one auth
pattern, one server-concurrency model. That's the opposite of Rails'
strategy (breadth via pluggability), which is why Monk stays around 8,600
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
`LISTEN`/`NOTIFY` (`monk add websocket --transport=postgres`), which drops Redis entirely
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
Action Mailer's `deliver_later` wouldn't: `Monk::Auth::SendLoginLink` creates
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
