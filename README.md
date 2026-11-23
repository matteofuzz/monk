# Monk

A light Ruby web framework designed to be fully `Ractor`-safe: every app it produces is a valid Rack 3 app that is also `Ractor.shareable?`, so it can be served in parallel across Ractor worker pools without silently losing that safety property. Named after Thelonious Sphere Monk, great and unique Jazz piano player and composer.

**Built in** (loaded by `require "monk"`): routing, context and error handling, plain HTML forms (form `params`, flash messages, other sites' requests refused, security headers), boot-time Ractor-shareability checks, `Monk::StateRactor` for shared state, settings, ERB views, static assets and logging. **Opt-in** (each needs its own `require`): Postgres persistence and migrations, passwordless auth and sessions, email, background jobs on Postgres, a WebSocket server with Redis or Postgres fan-out, `Monk::Live` server-pushed HTML updates, presence, file storage, an installable app and web push. Details for each are in the [Features](#features) table below.

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

`monk new` scaffolds the app's own `Gemfile` with `gem "monkrb", "~> 0.27", require: "monk"`.

`monk new` writes a working app: an HTML home page, a `/hello` route and a `/api/hello` JSON route, `public/`, its tests, a `SETUP.md`, and an `AGENTS.md` for coding agents. The app's own code goes under `app/`: `app/app.rb` and `app/routes/` for routes, `app/views/`, and one directory per role (`models/`, `presenters/`, `helpers/`, `mailers/`, `broadcasts/`, `jobs/`).

`monk add MODULE` adds a module to a new app or an old one, with its wiring, commented examples of how to use it, and a test; `monk new my_app --with auth,jobs` does both at once. [`docs/guides/scaffolding.md`](docs/guides/scaffolding.md) lists the modules and says where each kind of code goes.

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
| Forms | plain HTML forms: form bodies and nested `params`, `_method`, cross-site requests refused, `csrf_field` with auth, flash messages, redirects only to the app, security headers | — | [`forms.md`](docs/guides/forms.md) |
| Boot and shared state | `Monk.boot`, Ractor-shareability checks, `Monk::StateRactor` | — | [`boot-and-shared-state.md`](docs/guides/boot-and-shared-state.md) |
| Settings | `Monk::Settings`, `MONK_ENV`, env-var config validated at boot | — | [`settings.md`](docs/guides/settings.md) |
| Views and static assets | ERB compiled at boot, escaped by default, layouts/partials, frozen asset manifest | — | [`views.md`](docs/guides/views.md) |
| Logging | request log per environment, `Monk::Log.debug`/`info`/`warn`/`error` | — | [`logging.md`](docs/guides/logging.md) |
| Persistence | `Monk::Persistence::Pg`: raw `pg`, per-Ractor connections, hash-based `Model` | `require "monk/persistence/pg"` (+ `.../pg/model`); needs the `pg` gem | [`persistence.md`](docs/guides/persistence.md) |
| Migrations | plain `.sql` up/down pairs, `Migrator` | `require "monk/persistence/pg/migrator"`; needs the `pg` gem | [`migrations.md`](docs/guides/migrations.md) |
| Auth and sessions | `Monk::Auth`: passwordless tokens, Bearer or cookie + CSRF, a per-address login-email rate limit, nightly cleanup with jobs | `require "monk/auth"`; needs the `pg` gem and a registered Postgres connection | [`auth.md`](docs/guides/auth.md) |
| Email | `Monk::Mail`: text/HTML email over SMTP or a local relay, one `MAIL_URL`, sent from any worker Ractor, or from a background job with `deliver_later` | `require "monk/mail"`; `deliver_later` is there once `monk/jobs` is loaded too; SMTP needs the `net-smtp` gem | [`mail.md`](docs/guides/mail.md) |
| Background jobs | `Monk::Jobs`: a queue in Postgres, run by `bin/jobs` on worker Ractors; retries with backoff, scheduled jobs, recurring jobs on a cron schedule (UTC), enqueue inside the app's own transaction, `drain!` for tests | `require "monk/jobs"` (+ `require "monk/jobs/runtime"` in the job process); needs the `pg` gem and a registered Postgres connection | [`jobs.md`](docs/guides/jobs.md) |
| WebSocket | `Monk::WebSocket`: RFC 6455 server as its own process, Redis or Postgres fan-out | `require "monk/websocket"`; fan-out: `require "monk/websocket/redis_fanout"` (+ the `redis` gem) or `require "monk/websocket/pg_fanout"` (+ the `pg` gem) | [`websocket.md`](docs/guides/websocket.md) |
| Live updates | `Monk::Live`: server-rendered HTML patches pushed to open tabs | `require "monk/live"`; needs the WebSocket server and, across processes, Redis or Postgres | [`live.md`](docs/guides/live.md) |
| Presence | `Monk::Presence`: whether a signed-in person has a page open and visible (online), only hidden ones (away), or none (offline, with when they were last seen), across tabs, devices and WebSocket processes; an `on_change` hook in `bin/server` | `require "monk/presence"`; needs auth, the WebSocket server and Postgres; away needs Live | [`presence.md`](docs/guides/presence.md) |
| File storage | `Monk::Storage`: files by key in any S3-compatible bucket (Hetzner, R2, B2, AWS), local files in development and test; browser uploads and downloads through signed links, never through a worker Ractor | `require "monk/storage"`; no gem needed | [`storage.md`](docs/guides/storage.md) |
| Installable app | `Monk::Pwa`: a web app manifest, icons and a service worker (`/sw.js`), checked at boot and linked by `<%= monk_head %>`, so the app installs on a Home Screen or as a desktop app | `require "monk/pwa"`; no gem needed | [`pwa.md`](docs/guides/pwa.md) |
| Web push | `Monk::Push`: notifications to the devices where a signed-in person turned them on, encrypted and signed by Monk itself (RFC 8291, VAPID), one job per device; subscriptions tied to auth sessions | `require "monk/push"`; needs auth, jobs and Postgres, and pwa's service worker | [`push.md`](docs/guides/push.md) |
| Scaffolding | `monk new` and `monk add`: one generator per module, for a new app or an existing one; text or `--json` output; `monk add deploy` for Docker Compose and Caddy on one host | — (the `monk` command: `monk new NAME --with ...`, `monk add MODULE`, `monk add --list`) | [`scaffolding.md`](docs/guides/scaffolding.md) |

## More documentation

- [`docs/guides/`](docs/guides): one guide per feature (linked from the table above), and for running an app: [`deploying.md`](docs/guides/deploying.md), [`deploy-hetzner.md`](docs/guides/deploy-hetzner.md) (one app on a Hetzner Cloud server with Brevo for mail, every step, as tested) and [`upgrading.md`](docs/guides/upgrading.md).
- [`docs/design/`](docs/design): how the larger pieces work and why; start with [`ractor.md`](docs/design/ractor.md), how Monk uses Ruby's `Ractor`.
- [`docs/adr/`](docs/adr) and [`CONTEXT.md`](CONTEXT.md): architectural decisions and domain vocabulary.
- [`docs/framework-comparison.md`](docs/framework-comparison.md): Monk vs. Sinatra vs. Rails, with LOC per module.
- [`docs/history/`](docs/history): finished plans and research notes, for how a feature came to be.
- [`CHANGELOG.md`](CHANGELOG.md).

## Working on this repo

```
bundle install
bundle exec rake test    # Minitest
bin/server               # demo app from config.ru via kino
```

More (server modes, Docker) in [`docs/development.md`](docs/development.md).

## Status

Monk is **pre-1.0**: the API may still change between minor versions. What each release changed is in the [changelog](CHANGELOG.md), with the steps for an app made with an earlier Monk in [`docs/guides/upgrading.md`](docs/guides/upgrading.md); what comes next is in [`docs/roadmap.md`](docs/roadmap.md).

[Made with Love ❤️, Ruby 💎 and AI 🤖](docs/ai_usage_disclaimer.md)
