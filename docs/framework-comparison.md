# Monk vs. Sinatra vs. Rails

Complexity and weight comparison, based on the codebase at 0.27 (unreleased; LOC recomputed for it: settings, secrets and WebSocket origins refused at boot when they're wrong, `Monk::Mail.check` and `Monk::Storage.check`, and a code and test review that made both shorter). LOC is `wc -l` of every `.rb` file under `lib/` except the scaffold templates, and test LOC is `wc -l` of every `.rb` file under `test/`, the same method as earlier versions of this page.

## Footprint

- **Monk**: 13,433 lines of Ruby across 122 files (`lib/monk.rb` plus `lib/monk`, excluding the
  scaffold templates) — routing, context, plain HTML forms (form params,
  cross-site refusal, flash, security headers), ERB views/layouts,
  a boot-time static-asset manifest, settings/env tiers, auth
  (sessions/tokens/cookies/CSRF/rate-limiting), Postgres persistence + model +
  migrator + connection pools for Ractors, a full WebSocket stack (handshake, frames, connection
  registry, server, and cross-process broadcast fan-out over either Redis
  pub/sub or Postgres `LISTEN`/`NOTIFY`), email (`Monk::Mail`: its own MIME
  builder plus SMTP and log transports, sent inline or from a job),
  background jobs (`Monk::Jobs`: a Postgres queue, recurring jobs on a cron
  schedule, and a job process running worker Ractors), file storage
  (`Monk::Storage`: S3-compatible buckets through its own SigV4 signer,
  browser uploads and downloads by signed link, local files in
  development), presence (`Monk::Presence`: who has a page open and
  visible, across tabs, devices and processes, kept in Postgres), an
  installable app (`Monk::Pwa`) and web push (`Monk::Push`: its own
  RFC 8291 encryption and VAPID signing, no gem),
  `Monk::Live` (~630 lines of Ruby plus ~490 lines of browser JS and a
  vendored, minified idiomorph) for server-rendered live page updates, and
  the scaffolding that writes an app and adds each of these to it
  (`monk new`, `monk add`).
  Runtime dependencies: `rack` and `base64` only; `pg`, `redis`, `rqrcode`,
  `net-smtp` and `dotenv` are opt-in per app (dev-only for Monk itself), and `kino` is only in the
  repo's `Gemfile` for the demo app. 24,021 lines of tests.
- **Sinatra**: core is comparable in size (~2,000 lines), but ships as a
  thin routing DSL only — everything else (sessions/CSRF protection,
  persistence, websockets, live updates, presence, email, background
  jobs, file storage, web push) is a
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
| Scaffolding (`monk new`, `monk add`) | 20 | 1,815 | 3,336 (incl. `exe/monk`, and real `bin/websocket_server` processes counting presence) | the generator engine: plan every module and option, check every file, then write, incl. the sections modules add to SETUP.md, AGENTS.md and deploy's files (477); its result as text, JSON and an exit code (279); the CLI (303); the module DSL (163); the `bin/` scripts' error explanations and process spawning; one generator of ~20 lines per module |
| WebSocket | 11 | 1,765 | 2,591 (incl. one contract run on both fan-outs) | handshake, frames, connection incl. a heartbeat that closes a peer silent for two ping intervals and runs a per-connection check after each ping, server incl. `authenticate: :optional`, `db_pool:`, `presence:`, a cap on handshakes in flight and a handshake deadline, `SO_REUSEPORT`, stop on `TERM` and `allowed_origins:` checked at boot, registry incl. `close_all`, what both fan-outs share (`listen!` and registering), Redis fan-out, Postgres fan-out incl. pooled publishing, listeners that reconnect, a socket's connections closed when it ends |
| Jobs | 12 | 1,548 | 2,797 (incl. child job processes) | Postgres adapter incl. the scheduler's one statement per occurrence (361), runtime/supervisor (274), configure/enqueue/registry/`drain!`/`recurring`/`run_scheduler!`, cron parser (179), scheduler (90), `Monk::Job` and its settings, worker loop, argument check, errors, claim, firing and recurring-task values |
| Persistence | 8 | 1,483 | 1,743 | connection pools for Ractors (540: dispatcher, workers, errors that keep their class across Ractors), registry and checkout with the dropped-connection probe and pool lifecycle, Postgres model, migrator, Postgres backend incl. a `json`/`jsonb` decoder |
| Storage | 13 | 1,349 | 1,924 (incl. a fake S3 server, and one contract run on both backends and against floci) | S3 backend over `Net::HTTP` incl. `check` of a bucket's CORS and lifecycle rules (248), file backend that behaves like a bucket (247), configure and the API (193), `STORAGE_URL` parsing (126), SigV4 signer (123), the `/_monk/storage` routes (109), input checks, `Sniff`, HMAC tokens, keys, errors |
| Core | 11 | 1,270 | 3,049 (core + shared helpers) | `Monk::Base` routing/dispatch incl. route blocks defined as methods at `freeze!`, form and JSON bodies with a 1 MB cap, `_method`, the cross-site check and security headers (470); nested `params` (81); settings incl. `PUBLIC_URL` and `LIVE_WS_URL` refused at boot when wrong, logging, context incl. `monk_head`, `redirect` to this app only and `flash`, environment, errors, `StateRactor`, freeze hooks |
| Push | 11 | 816 | 780 (incl. a push service on loopback that decrypts each message as a browser would) | configure and the API incl. the boot check of the key pair and contact (190), the subscriptions' SQL, tied to auth sessions (123), delivery and the push service's answers (119), keys, `aes128gcm` encryption, the VAPID token, subscription parsing, `notify` and its job (loaded with jobs) |
| Presence | 5 | 759 | 1,164 (incl. the reactor as a child process, and a real browser) | the store's SQL: rows per process, transitions settled once under an advisory lock, `NOTIFY` in batches, expiry of a dead process's rows (274); configure, `status`/`online?` and `on_change` (130); the reactor in `bin/server`, elected by an advisory lock, that `LISTEN`s and calls `on_change` (126); the per-process counts Ractor (118) and the tracker thread that writes them once a second (111) |
| Auth | 8 | 726 | 1,729 | sessions, tokens, cookies, CSRF incl. `csrf_field` and a stale cookie reissued, a placeholder or short secret refused at boot, the login-email rate limit, batched `sweep!` and its job, per-process rate limiter, link delivery and `login_link`, `SendLoginLink`, helpers incl. `log_out!` |
| Mail | 9 | 675 | 1,396 (incl. a fake SMTP server) | MIME builder, configure/deliver/render, `check` of `MAIL_URL`'s login without sending, SMTP and log transports, `MAIL_URL` parsing, message value, `deliver_later` and its job (loaded with jobs), address handling |
| Live | 8 | 633 | 2,437 (incl. one contract run on both fan-outs) | publisher, session incl. the client's ping and `hidden` messages and whether its page is visible, policy incl. pooled rules, renderer, envelope, `live_topic` and its `<head>` tags, `listen!`, the client served from the gem |
| Assets | 1 | 230 | 293 | boot-time static-asset manifest, plus modules' own files mounted under `/_monk/` |
| Views | 1 | 203 | 366 | ERB views/layouts/partials |
| Pwa | 4 | 161 | 416 (incl. real headless Chrome) | the manifest checked the way Chrome does (74), configure, `monk_head`'s tags, errors |
| **Total** | **122** | **13,433** | **24,021** | |

Not counted above: the browser code, Live's runtime (`monk_live.js` 365,
`protocol.js` 129, vendored minified idiomorph), push's (`push.js` 132,
`state.js` 65) and pwa's `register.js` (47), the app's `sw.js` template,
and the JS tests under `test/js`.

Live has the highest test-to-code ratio (about 4:1) because it is covered
by real-browser and multi-process tests, run against both fan-out
transports, and since 0.24 against a proxy that drops a socket without
closing it, as a phone changing networks does. Presence, new in 0.24, is
about 1.5:1, plus its generator's tests: they run real
`bin/websocket_server` processes and kill them with `KILL`, checking that
a person still connected through another process stays online.
Push, new in 0.25, is about 1:1, but its delivery tests send every
message through a real push service on loopback that decrypts it as a
browser would; subscribing in a real browser can't be tested headless,
so it was checked on devices (iPhone, Android, and Chrome, Safari and
Firefox on macOS).
Scaffolding is the largest module, but it is tooling, not runtime: no app
loads it. Its tests generate real apps and run their own
suites, uncomment every example and exercise it (a real socket for the
chat example), check that every pair of modules gives the same app in
either order, and run the modules that look for each other together, and
all 11 at once.
WebSocket is the largest runtime module, after 0.22.1's work on connect
bursts and 0.24's heartbeat; in 0.27 what its two fan-outs share moved
into one module, and their tests into one contract run on both.
Persistence grew in 0.20 with connection pools (a dispatcher Ractor and worker Ractors that
own the connections, since a connection can't move between Ractors) and
recovery from a dropped connection. WebSocket grew with it: both fanouts'
listeners now reconnect and make open pages resync, and the server can
check sessions through a pool. Most of Jobs is the Postgres adapter's SQL (one statement per operation, so a job's
state never needs a multi-statement transaction, and one per recurring
occurrence, so job processes never enqueue it twice), the supervisor's
crash recovery (respawning dead worker Ractors, releasing the job a dead
worker held, and reconnecting after a database restart), and its own
cron parser, since Monk adds no gem for it. Its tests (about
1.8:1) run real child job processes, stopped with `TERM` and `kill -9`,
and kill their database connections mid-run. Mail is about 2:1: every
SMTP test sends from a real worker Ractor to a fake SMTP server, over plain
connections, STARTTLS and implicit TLS.

## Side by side

| | Sinatra | Monk | Rails |
|---|---|---|---|
| Core LOC | ~2,000 (comparable) | ~13,400 (+ ~740 JS) | hundreds of thousands across railties/AP/AR/AS/etc. |
| Runtime deps | rack, rack-protection, tilt, mustermann | rack, base64 | ~10 first-party gems, each with their own tree (~30+ total) |
| Feature scope | routing + DSL only — everything else is a gem you bolt on | routing, plain HTML forms with cross-site refusal and security headers, views/layouts, static assets, settings/env, auth, Postgres ORM + migrator, websockets incl. Redis or Postgres fan-out, live HTML patching, presence, text/HTML email over SMTP, background jobs on Postgres, file storage in S3-compatible buckets, an installable app and web push — all built-in and opinionated (ERB only, Postgres only, one auth scheme) | routing, ORM (multi-DB), views (multi-engine), jobs, mailers, cable, storage, text, i18n, asset pipeline — pluggable at every layer |
| Concurrency model | none prescribed — thread-safety is your problem | Ractor-safety is load-bearing: routes/handlers are statically checked to be `Ractor.shareable?` at boot | threads/processes; no Ractor-native design |
| Live page updates | none — bring your own websocket gem and client JS | `Monk::Live`: render a partial once, push it to topic subscribers, client morphs it in; deny-by-default subscribe rules; resync by refetch; reconnects when a phone's page is shown again. Server → client only. Presence (`Monk::Presence`): online, away (only hidden pages) or offline per signed-in person, with an `on_change` hook | Action Cable + Turbo Streams (`turbo-rails`): broadcast partials, plus client → server channels, presence-style patterns, and pluggable adapters |
| Email | none — bring the `mail` gem (or `pony`) and configure it yourself | `Monk::Mail`: text and/or HTML (from a view), MIME built by Monk, one `MAIL_URL` (any provider's SMTP relay or a local one), sent from the worker Ractor, or from the job process with `deliver_later`; `Monk::Mail.check` tests the login without sending. No attachments, no previews | Action Mailer: mailer classes and views, attachments, previews, interceptors, `deliver_later` via Active Job, pluggable delivery methods |
| Background jobs | none — bring Sidekiq (and Redis) or a database-backed queue gem | `Monk::Jobs`: a Postgres-only queue (a narrow state table plus a payload table, `SKIP LOCKED`) and a job process, `bin/jobs`, running worker Ractors. Retries with backoff, scheduled jobs, recurring jobs on a cron schedule (UTC), `never_retry`, enqueue inside the app's own transaction, `drain!` and `run_scheduler!` for tests; at-least-once. No concurrency limits, pausing, batches or dashboard | Active Job with a pluggable backend; since Rails 8 Solid Queue (database-backed) by default, with recurring tasks, concurrency controls, pausing, and a dashboard (Mission Control, a separate gem) |
| File storage | none — bring `shrine` or `aws-sdk-s3`, and parse uploads yourself | `Monk::Storage`: one S3-compatible backend (SigV4 written in Monk, no gem) and local files in development and test that behave like a bucket. Browsers upload straight to the bucket through a presigned PUT and download through an app route that redirects to a signed link, so no worker Ractor waits on the bytes; the first bytes tell the common types apart; `Monk::Storage.check` reads a bucket's CORS and lifecycle rules without writing. No attachments model, no variants, no multipart uploads | Active Storage: attachments on models, variants and previews, direct uploads, mirroring, pluggable services (S3, GCS, Azure Blob, disk) |
| Web push | none — bring the `web-push` gem, a service worker and the page's subscribe code | `Monk::Push`: encryption and VAPID signing written in Monk over OpenSSL (no gem), one job per device, subscriptions tied to auth sessions (logout stops a device's notifications), rows deleted when the push service says they're gone; `push.js` for the page's switch, and `monk add pwa` for the manifest and service worker it needs. Notifications only, no silent pushes, no native apps | a PWA manifest and service worker in a new app; web push itself is the `web-push` gem and the app's own code |
| Scaffolding | none built in | `monk new` makes the core app, `monk add <module>` adds a module to any app, new or old: one generator per module, which only creates files and appends lines, adding its dependencies first. Each brings its wiring, commented examples of how to use it (tested by Monk), a test in the app, and `SETUP.md`/`AGENTS.md` sections; `monk add deploy` builds a Docker Compose stack from the modules installed; `--json` and exit codes for agents | `rails new` with its options, then `bin/rails generate` (resources, `authentication`) and install tasks (`solid_queue:install`, ...) that edit existing files; app templates for recipes |
| "Magic" | almost none — DSL is thin, behavior is traceable | almost none — explicit `Context`, explicit boot/freeze step, explicit `StateRactor` for shared mutable state | heavy convention-over-configuration (autoloading, callbacks, concerns, generators) — powerful but harder to trace |

## Takeaways

Monk carries meaningfully more feature scope than Sinatra ships with while
staying more than an order of magnitude under Rails, achieved by narrowing choices
rather than adding abstraction: one template engine, one database, one auth
pattern, one server-concurrency model. That's the opposite of Rails'
strategy (breadth via pluggability), which is why Monk stays around 13,000
lines of Ruby while doing things Sinatra needs `sinatra-contrib` + `warden` +
`sequel`/`activerecord` + `faye-websocket` + `mail` + `sidekiq` (and Redis)
+ `aws-sdk-s3` or `shrine` + `web-push`
(plus a hand-rolled Redis or Postgres fan-out for cross-process broadcast,
and your own DOM-patching client) to match.

`Monk::Live` is the closest Monk gets to a Rails feature by design: it
covers the Turbo Streams use case (server-owned state changes, every tab
updates) using the views the app already has. It is deliberately narrower:
server → client only (no `onclick`/forms over the socket), no
replay of missed messages (a resync refetches the page), no per-viewer
diffing, and subscription rules are checked only at subscribe time. It also
needs two processes plus a cross-process transport, because
`Monk::WebSocket` cannot share a process with Kino. That transport is Redis,
or — for an app that already runs Postgres — `PgFanout` over
`LISTEN`/`NOTIFY` (`monk add websocket --transport=postgres`), which drops Redis entirely
at the cost of a ~8KB per-broadcast cap and lower throughput than Redis
once there are many WS processes or a hot topic.
The trade mirrors Action Cable's own Redis vs. PostgreSQL adapters (same
`NOTIFY` limit). Rails' Action Cable runs in-process with the app and
supports more adapters, at a much higher weight.

`Monk::Mail` exists for a Ractor reason, not a scope one: the `mail` gem,
and so Action Mailer, raises `Ractor::IsolationError` as soon as a message is
built in a worker Ractor (class variables and a `Singleton` config), so a
Monk app can't bring the usual mailer. It covers what an app actually sends
(magic links, notifications) in about 680 lines and is much narrower than
Action Mailer: no attachments, no previews. `deliver` blocks the worker for
its duration (ADR 0012), while `deliver_later` sends from the job process,
retrying only failures that can succeed later. One thing it does that
Action Mailer's `deliver_later` wouldn't: `Monk::Auth::SendLoginLink` creates
a login token inside the job that sends it, so the raw token is never
written to the queue, keeping `Monk::Auth`'s "only hashes in the database"
guarantee (ADR 0014).

`Monk::Storage` exists for a Ractor reason too, and it shaped the design
more than the code. Rack's multipart parser can't run in a worker Ractor
(ADR 0018), so instead of parsing uploads Monk keeps them out of the app:
the browser PUTs to the bucket through a link the app signs, and the app
only checks the result. It is much narrower than Active Storage: Monk
stores bytes by key and the app keeps its own records, with no model,
no image variants and no mirrors, in about 1,350 lines, a fifth of them
the file backend that lets tests catch what a bucket would refuse.

`Monk::Jobs` exists for much the same reason. No Ruby job library is
Ractor-aware, and the database-backed ones build on Active Record, which
fails in a worker Ractor just as Sequel did (ADR 0013). It is a
Postgres-only queue, run by `bin/jobs` on worker Ractors, so jobs run in
parallel within one process rather than taking turns on one interpreter
lock as threads do. Its table layout was chosen by benchmarking it against
Solid Queue's multi-table split and a single wide table (ADR 0013,
`docs/history/plan-jobs.md` Phase 0). It is much narrower than Active Job
with Solid Queue: no concurrency limits, no pausing, no
batches, no dashboard, one backend. Delivery is at-least-once, so jobs must
be safe to repeat.

`Monk::Presence` has no counterpart in either: Rails apps usually build
it themselves on Action Cable's `subscribed`/`unsubscribed` callbacks and
Redis. Monk's lives in the app's Postgres, one row per WebSocket process
and person, so a process that dies without closing its sockets is cleaned
up when its rows expire, and each change (online, away, offline) is
settled once however many processes see it (ADR 0019). Away is what a
phone needs: a locked iPhone's page reads away at once and offline about
25 s later, measured on real devices, in about 750 lines.

The one place Monk carries complexity neither of the others has: the
Ractor-shareability guarantees (`.freeze!`, `UnshareableRouteError`,
`StateRactor`). That's real conceptual weight — a constraint Sinatra and
Rails users never have to think about — but it's the framework's actual
reason to exist, not incidental bloat.

Note on `rack-protection` (Sinatra's default protection middleware suite).
Since 0.26, Monk covers its most useful parts in core, on by default:
- other sites' browser POST/PUT/PATCH/DELETE requests are refused on
  every route, with or without auth (modeled on Go's
  `CrossOriginProtection`);
- `nosniff`, `frame-ancestors 'none'` and a referrer policy on every
  response;
- `redirect` only to the app.

The `auth` module adds a stateless double-submit CSRF token
(`require_csrf!`, the header or `csrf_field`) for cookie sessions. The
rest of `rack-protection` (path traversal, session hijacking heuristics,
IP spoofing) can still be added by requiring it, since Monk apps are
plain Rack underneath.

**Bottom line**: closer to Sinatra than Rails in weight and boot cost
(small dependency graph, no autoloading, no framework-managed process
boundary), but not really "Sinatra-style" in scope — it's a
batteries-included micro-framework where the batteries are deliberately
non-swappable. Rails is a different category entirely: comparing LOC is
almost apples-to-oranges given Rails' pluggable-everything architecture.
