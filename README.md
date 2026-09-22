# Monk

A light Ruby web framework designed to be fully `Ractor`-safe: every app it produces is a valid Rack 3 app that is also `Ractor.shareable?`, so it can be served in parallel across Ractor worker pools without silently losing that safety property. Named after Thelonious Sphere Monk, great and unique Jazz piano player and composer.

**Built in** (loaded by `require "monk"`): routing, context and error handling, boot-time Ractor-shareability checks, `Monk::StateRactor` for shared state, settings, ERB views, static assets and logging. **Opt-in** (each needs its own `require`): Postgres persistence and migrations, passwordless auth and sessions, a WebSocket server with Redis fan-out, and `Monk::Live` server-pushed HTML updates. Details for each are in the [Features](#features) table below.

Monk is Kino-agnostic — it's built on stdlib `Ractor` primitives only, with no runtime dependency on any particular server. [Kino](https://github.com/yaroslav/kino) is the reference/development server (see `bin/server`), but any Ractor-aware Rack server, or a conventional one, can run a Monk app.

Requires **Ruby 4.0+**. Runtime dependencies: `rack` and `base64`.

## Quick start

Install the gem — published as `monkrb` (the `monk` name on RubyGems belongs to an unrelated, long-abandoned project), the CLI and `require` stay `monk`:

```
gem install monkrb

monk new my_app && cd my_app
bundle install
bin/server           # -> http://localhost:9292/hello
```

`monk new` scaffolds the app's own `Gemfile` with `gem "monkrb", require: "monk"`.

`monk new` writes a working skeleton (an HTML home page, a `/hello` route, a `/api/hello` JSON route, `views/`, `public/`, a `SETUP.md`). Flags add Postgres, auth, Redis and live updates: see [`docs/guides/scaffolding.md`](docs/guides/scaffolding.md).

All `monk` commands and flags are listed by:

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
| WebSocket | `Monk::WebSocket`: RFC 6455 server as its own process, Redis fan-out | `require "monk/websocket"`; Redis fan-out: `require "monk/websocket/redis_fanout"` and the `redis` gem | [`websocket.md`](docs/guides/websocket.md) |
| Live updates | `Monk::Live`: server-rendered HTML patches pushed to open tabs | `require "monk/live"`; needs the WebSocket server and, across processes, Redis | [`live.md`](docs/guides/live.md) |
| Scaffolding | `monk new` and its flags; retrofitting Postgres, Auth or Redis | — (the `monk` command; flags `--postgres`, `--auth`, `--redis`, `--live`) | [`scaffolding.md`](docs/guides/scaffolding.md) |

## More documentation

- [`docs/framework-comparison.md`](docs/framework-comparison.md): Monk vs. Sinatra vs. Rails, with LOC per module.
- [`docs/guides/deploying.md`](docs/guides/deploying.md): worked deployment examples.
- [`docs/design/ractor.md`](docs/design/ractor.md): how Monk uses Ruby's `Ractor`.
- [`docs/adr/`](docs/adr) and [`CONTEXT.md`](CONTEXT.md): architectural decisions and domain vocabulary.
- Design docs and phase-by-phase plans behind each feature: [`docs/design/views.md`](docs/design/views.md), [`docs/design/auth-sessions.md`](docs/design/auth-sessions.md), [`docs/design/websocket.md`](docs/design/websocket.md), [`docs/design/persistence-ractor-connections.md`](docs/design/persistence-ractor-connections.md), and the phase-by-phase plans and archived notes in [`docs/history/`](docs/history).
- [`CHANGELOG.md`](CHANGELOG.md).

## Working on this repo

```
bundle install
bundle exec rake test    # Minitest
bin/server               # demo app from config.ru via kino
```

More (server modes, Docker) in [`docs/development.md`](docs/development.md).

## Status

Monk is **pre-1.0** (see `lib/monk/version.rb` and the [changelog](CHANGELOG.md)): the API may still change between minor versions. The core is described in [`docs/history/core-plan.md`](docs/history/core-plan.md). There's no open roadmap issue at the moment; new work is proposed and tracked as it comes up. Done so far, each with its own design doc and plan: persistence, migrations, HTML templating and static assets, auth and sessions, WebSocket with Redis fan-out, log levels, live updates (`Monk::Live`, as of 2026-09-19), deployment support (Dockerfile scaffolding, `docs/guides/deploying.md`), and the RubyGems release as `monkrb` (both 2026-09-22).
