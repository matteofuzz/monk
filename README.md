# Monk

A light Ruby web framework designed to be fully `Ractor`-safe: every app it produces is a valid Rack 3 app that is also `Ractor.shareable?`, so it can be served in parallel across Ractor worker pools without silently losing that safety property. Named after Thelonious Sphere Monk, great and unique Jazz piano player and composer.

Monk is Kino-agnostic — it's built on stdlib `Ractor` primitives only, with no runtime dependency on any particular server. [Kino](https://github.com/yaroslav/kino) is the reference/development server (see `bin/server`), but any Ractor-aware Rack server, or a conventional one, can run a Monk app.

Requires **Ruby 4.0+**. Runtime dependencies: `rack` and `base64`.

## Quick start

```
monk new my_app && cd my_app
bundle install
bin/server           # -> http://localhost:9292/hello
```

`monk new` writes a working skeleton (an HTML home page, a `/hello` route, a `/api/hello` JSON route, `views/`, `public/`, a `SETUP.md`). Flags add Postgres, auth, Redis and live updates: see [`docs/scaffolding.md`](docs/scaffolding.md).

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

| Feature | What it is | Guide |
|---|---|---|
| Routing, context, errors | `get`/`post`/…, path params, `halt`, `json`, `error`, experimental `resources` | [`routing.md`](docs/routing.md) |
| Boot and shared state | `Monk.boot`, Ractor-shareability checks, `Monk::StateRactor` | [`boot-and-shared-state.md`](docs/boot-and-shared-state.md) |
| Settings | `Monk::Settings`, `MONK_ENV`, env-var config validated at boot | [`settings.md`](docs/settings.md) |
| Views and static assets | ERB compiled at boot, escaped by default, layouts/partials, frozen asset manifest | [`views-and-assets.md`](docs/views-and-assets.md) |
| Logging | request log per environment, `Monk::Log.debug`/`info`/`warn`/`error` | [`logging.md`](docs/logging.md) |
| Persistence | `Monk::Persistence::Pg`: raw `pg`, per-Ractor connections, hash-based `Model` | [`persistence.md`](docs/persistence.md) |
| Migrations | plain `.sql` up/down pairs, `Migrator` | [`migrations.md`](docs/migrations.md) |
| Auth and sessions | `Monk::Auth`: passwordless tokens, Bearer or cookie + CSRF | [`auth.md`](docs/auth.md) |
| WebSocket | `Monk::WebSocket`: RFC 6455 server as its own process, Redis fan-out | [`websocket-server.md`](docs/websocket-server.md) |
| Live updates | `Monk::Live`: server-rendered HTML patches pushed to open tabs | [`live.md`](docs/live.md) |
| Scaffolding | `monk new` and its flags; retrofitting Postgres, Auth or Redis | [`scaffolding.md`](docs/scaffolding.md) |

## More documentation

- [`docs/framework-comparison.md`](docs/framework-comparison.md): Monk vs. Sinatra vs. Rails, with LOC per module.
- [`docs/deploying.md`](docs/deploying.md): worked deployment examples.
- [`docs/ractor.md`](docs/ractor.md): how Monk uses Ruby's `Ractor`.
- [`docs/adr/`](docs/adr) and [`CONTEXT.md`](CONTEXT.md): architectural decisions and domain vocabulary.
- Design docs and phase-by-phase plans behind each feature: [`docs/views.md`](docs/views.md), [`docs/auth-sessions.md`](docs/auth-sessions.md), [`docs/websocket.md`](docs/websocket.md), [`docs/persistence-ractor-connections.md`](docs/persistence-ractor-connections.md), [`docs/reactive-partials.md`](docs/reactive-partials.md), and the `PLAN-*.md` files.
- [`CHANGELOG.md`](CHANGELOG.md).

## Working on this repo

```
bundle install
bundle exec rake test    # Minitest
bin/server               # demo app from config.ru via kino
```

More (server modes, Docker) in [`docs/development.md`](docs/development.md).

## Status

v1 is done (`PLAN.md`); Monk is now on v2, worked one candidate at a time. The living list is [issue #19](https://github.com/matteofuzz/monk/issues/19) (seeded from `NOTES-V2.md`). Done so far, each with its own design doc and plan: persistence, migrations, HTML templating and static assets, auth and sessions, WebSocket with Redis fan-out, log levels, and live updates (`Monk::Live`, as of 2026-09-19).
