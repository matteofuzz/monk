# Monk

A light Ruby web framework designed to be fully `Ractor`-safe: every app it produces is a valid Rack 3 app that is also `Ractor.shareable?`, so it can be served in parallel across Ractor worker pools without silently losing that safety property. Named after Thelonious Sphere Monk, great and unique Jazz piano player and composer.

**Built in** (loaded by `require "monk"`): routing, context and error handling, boot-time Ractor-shareability checks, `Monk::StateRactor` for shared state, settings, ERB views, static assets and logging. **Opt-in** (each needs its own `require`): Postgres persistence and migrations, passwordless auth and sessions, email, background jobs on Postgres, a WebSocket server with Redis or Postgres fan-out, and `Monk::Live` server-pushed HTML updates. Details for each are in the [Features](#features) table below.

Monk is Kino-agnostic — it's built on stdlib `Ractor` primitives only, with no runtime dependency on any particular server. [Kino](https://github.com/yaroslav/kino) is the reference/development server (see `bin/server`), but any Ractor-aware Rack server, or a conventional one, can run a Monk app.

Requires **Ruby 4.0+**. Runtime dependencies: `rack` and `base64`.

## Quick start

Install the gem — published as `monkrb` (the `monk` name on RubyGems belongs to an unrelated, long-abandoned project), the CLI and `require` stay `monk`:

```
gem install monkrb

monk new my_app && cd my_app
bundle install
bin/server           # -> http://localhost:9292/hello
monk add --list      # the modules you can add: postgres, auth, jobs, live...
```

`monk new` scaffolds the app's own `Gemfile` with `gem "monkrb", require: "monk"`.

`monk new` writes a working skeleton (an HTML home page, a `/hello` route, a `/api/hello` JSON route, `public/`, its tests, a `SETUP.md` and an `AGENTS.md` for coding agents), with the app's own code under `app/`: `app/app.rb` and `app/routes/` for routes, `app/views/`, and one directory per role (`models/`, `presenters/`, `helpers/`, `mailers/`, `broadcasts/`, `jobs/`). `monk add` adds Postgres, Redis, email, auth, background jobs, WebSocket and live updates, to a new app or an old one, each with its wiring, commented examples of how to use it, and a test (`monk new my_app --with auth,jobs` does both at once): see [`docs/guides/scaffolding.md`](docs/guides/scaffolding.md), which also says where each kind of code goes.

All `monk` commands and options are listed by:

```
monk --help
```

## A taste

```ruby
class App < Monk::Base
  get("/hello") { "hello from monk" }
  get("/users/:id") { json(id: params[:id]) }
  get("/") { @title = "Home"; render "index", posts: Post.where(published: true) }

  error(404) { json(error: "not found") }
end

run Monk.boot(App)   # seals routes into a Ractor.shareable? structure, or raises
```

Routes can't close over mutable state: `Monk.boot` raises `Monk::UnshareableRouteError` naming the offending route instead of failing on a live request. Shared mutable state goes through `Monk::StateRactor`.

## Features

Everything beyond the core is opt-in (`require "monk"` alone loads none of it).

| Feature | What it is | Opt-in | Guide |
|---|---|---|---|
| Routing, context, errors | `get`/`post`/…, path params, `halt`, `json`, `error`, experimental `resources` | — | [`routing.md`](docs/guides/routing.md) |
| Boot and shared state | `Monk.boot`, Ractor-shareability checks, `Monk::StateRactor` | — | [`boot-and-shared-state.md`](docs/guides/boot-and-shared-state.md) |
| Settings | `Monk::Settings`, `MONK_ENV`, env-var config validated at boot | — | [`settings.md`](docs/guides/settings.md) |
| Views and static assets | ERB compiled at boot, escaped by default, layouts/partials, frozen asset manifest | — | [`views.md`](docs/guides/views.md) |
| Logging | request log per environment, `Monk::Log.debug`/`info`/`warn`/`error` | — | [`logging.md`](docs/guides/logging.md) |
| Persistence | `Monk::Persistence::Pg`: raw `pg`, per-Ractor connections, hash-based `Model` | `require "monk/persistence/pg"` (+ `.../pg/model`); needs the `pg` gem | [`persistence.md`](docs/guides/persistence.md) |
| Migrations | plain `.sql` up/down pairs, `Migrator` | `require "monk/persistence/pg/migrator"`; needs the `pg` gem | [`migrations.md`](docs/guides/migrations.md) |
| Auth and sessions | `Monk::Auth`: passwordless tokens, Bearer or cookie + CSRF | `require "monk/auth"`; needs the `pg` gem and a registered Postgres connection | [`auth.md`](docs/guides/auth.md) |
| Email | `Monk::Mail`: text/HTML email over SMTP or a local relay, one `MAIL_URL`, sent from any worker Ractor, or from a background job with `deliver_later` | `require "monk/mail"`; `deliver_later` is there once `monk/jobs` is loaded too; SMTP needs the `net-smtp` gem | [`mail.md`](docs/guides/mail.md) |
| Background jobs | `Monk::Jobs`: a queue in Postgres, run by `bin/jobs` on worker Ractors; retries with backoff, scheduled jobs, enqueue inside the app's own transaction, `drain!` for tests | `require "monk/jobs"` (+ `require "monk/jobs/runtime"` in the job process); needs the `pg` gem and a registered Postgres connection | [`jobs.md`](docs/guides/jobs.md) |
| WebSocket | `Monk::WebSocket`: RFC 6455 server as its own process, Redis or Postgres fan-out | `require "monk/websocket"`; fan-out: `require "monk/websocket/redis_fanout"` (+ the `redis` gem) or `require "monk/websocket/pg_fanout"` (+ the `pg` gem) | [`websocket.md`](docs/guides/websocket.md) |
| Live updates | `Monk::Live`: server-rendered HTML patches pushed to open tabs | `require "monk/live"`; needs the WebSocket server and, across processes, Redis or Postgres | [`live.md`](docs/guides/live.md) |
| Scaffolding | `monk new` and `monk add`: one generator per module, for a new app or an existing one; text or `--json` output | — (the `monk` command: `monk new NAME --with ...`, `monk add MODULE`, `monk add --list`) | [`scaffolding.md`](docs/guides/scaffolding.md) |

## More documentation

- [`docs/framework-comparison.md`](docs/framework-comparison.md): Monk vs. Sinatra vs. Rails, with LOC per module.
- [`docs/guides/deploying.md`](docs/guides/deploying.md): worked deployment examples.
- [`docs/design/ractor.md`](docs/design/ractor.md): how Monk uses Ruby's `Ractor`.
- [`docs/adr/`](docs/adr) and [`CONTEXT.md`](CONTEXT.md): architectural decisions and domain vocabulary.
- Design docs and phase-by-phase plans behind each feature: [`docs/design/views.md`](docs/design/views.md), [`docs/design/auth-sessions.md`](docs/design/auth-sessions.md), [`docs/design/websocket.md`](docs/design/websocket.md), [`docs/design/persistence-ractor-connections.md`](docs/design/persistence-ractor-connections.md), [`docs/design/live-pg-fanout.md`](docs/design/live-pg-fanout.md), and the phase-by-phase plans and archived notes in [`docs/history/`](docs/history).
- [`CHANGELOG.md`](CHANGELOG.md).

## Working on this repo

```
bundle install
bundle exec rake test    # Minitest
bin/server               # demo app from config.ru via kino
```

More (server modes, Docker) in [`docs/development.md`](docs/development.md).

## Status

Monk is **pre-1.0** (see `lib/monk/version.rb` and the [changelog](CHANGELOG.md)): the API may still change between minor versions. The core is described in [`docs/history/core-plan.md`](docs/history/core-plan.md). Features to add are listed in [`docs/roadmap.md`](docs/roadmap.md). Done so far, each with its own design doc and plan: persistence, migrations, HTML templating and static assets, auth and sessions, WebSocket with Redis fan-out, log levels, live updates (`Monk::Live`, as of 2026-09-19), deployment support (Dockerfile scaffolding, `docs/guides/deploying.md`), the RubyGems release as `monkrb` (both 2026-09-22), and `Monk::WebSocket::PgFanout`/`monk new --live --postgres` — the same cross-process fan-out over Postgres `LISTEN`/`NOTIFY` instead of Redis, for an app that doesn't want a second piece of infrastructure (`docs/design/live-pg-fanout.md`, 2026-09-24), the built-in mailer `Monk::Mail` (0.17, 2026-09-26, ADR 0012), and background jobs on Postgres, `Monk::Jobs`, with mail sent from jobs (0.18, 2026-09-29, ADRs 0013 and 0014). In 0.19 (2026-10-01): `monk new` lays the app out under `app/`, one directory per role (ADR 0015); a WebSocket fanout listens only in the process that holds the sockets (`#listen!`); `authenticate: :optional` lets visitors' sockets in anonymously, for Live's rules to decide; and the WebSocket server stops cleanly on `TERM` (`docs/design/websocket.md`). In 0.20 (2026-10-05): Monk recovers from a dropped database connection (a Postgres restart, a failover) without a process restart. `checkout` reconnects a dead connection before running its block, never retrying the block itself; both fanouts' listeners reconnect and then make every open page resync; and a route that raises logs why (`docs/history/plan-pg-reconnect.md`). Also new: connection pools for Ractors that shouldn't each hold a connection (`Monk::Persistence::Pg.pool`). The WebSocket server's session checks, Live's subscribe rules and `PgFanout`'s publisher can run through one, so open pages share a few connections instead of holding one each: 1,000 open sockets on 4 connections (`docs/guides/persistence.md`, "Pools"; `docs/history/plan-pg-pool.md`). In 0.21 (2026-10-09): scaffolding by module. `monk new` makes the core app, and `monk add` adds a module (Postgres, Redis, mail, auth, jobs, WebSocket, Live) to any app, new or existing, with its wiring, commented examples, a test, and its sections of `SETUP.md` and an `AGENTS.md` for coding agents; `--json` for agents and scripts. Redis and WebSocket become modules of their own, the WebSocket transport is chosen once per app, and `monk new`'s module flags are gone (ADR 0017, `docs/guides/scaffolding.md`, `docs/history/plan-scaffold.md`).

[Made with Love ❤️, Ruby 💎 and AI 🤖](docs/ai_usage_disclaimer.md)
