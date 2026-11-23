# Settings — `Monk::Settings`

App-level configuration, declared once via `configure` and read back anywhere with `Monk::Settings[:key]` or, inside a route, `settings[:key]`:

```ruby
Monk::Settings.configure do
  required :api_key
  optional :port, default: "9292"
end

Monk::Settings[:api_key] # reads ENV["API_KEY"]
```

Each declared key reads from the uppercased env var of the same name, falling back to its default if optional. `MONK_ENV` is a built-in key every app gets for free — validated at boot against `development`/`test`/`staging`/`production` — and `Monk.env` returns a frozen `Environment` object with `.development?`/`.test?`/`.staging?`/`.production?` predicates.

`Monk.boot(App)` — the same step that freezes routes — checks every required key is present and freezes the resolved values into a `Ractor.shareable?` snapshot, so a worker Ractor can read `Settings[:key]` without `Ractor::IsolationError`. A missing required key raises `MissingSettingError` at boot rather than on the first request that needs it; `configure` after boot raises `SettingsFrozenError`; reading a key nobody declared raises `UnknownSettingError` either way.

## Values refused at boot

Some values are present but wrong, and would otherwise fail silently, the
first time someone uses the app. Boot refuses them with
`Monk::InvalidSettingError` (or `Monk::InvalidAuthConfigError` for the
secret), naming the variable and the fix. Every process checks them: the
web server, `bin/jobs` and `bin/websocket_server`.

| Value | Refused | Why |
|---|---|---|
| `PUBLIC_URL` | in every environment, unless it's an origin only: `https://app.your-domain.com`, no path or trailing slash | It's compared exactly with the browser's `Origin` header (the WebSocket's allowed origins), which never has one |
| `PUBLIC_URL` | in staging and production, on `http://` | The session cookie is `Secure` there, so nobody would stay signed in |
| `PUBLIC_URL` | in staging and production, on a placeholder host: `example.com`/`.net`/`.org`, `*.example`, `*.test`, `*.invalid` | Every magic link would point nowhere. `localhost` and IP addresses pass |
| `LIVE_WS_URL` | in staging and production, unless `wss://` | An `https://` page can't open a `ws://` socket |
| `AUTH_SECRET` | in staging and production, if it contains `change-me` or is shorter than 32 characters | It signs every session. `openssl rand -hex 32` makes one |
| `WS_ALLOWED_ORIGINS` | in every environment, an entry that isn't an origin | Same as `PUBLIC_URL`: it could never match |

`PUBLIC_URL` and `LIVE_WS_URL` are declared by the app
(`config/settings.rb`, `config/live.rb`), but Monk reads them, so it
checks them whenever they're declared.

To try the production behaviour locally, run the deploy stack
(`monk add deploy`) with `MONK_ENV=production`,
`PUBLIC_URL=https://localhost` and `SITE_ADDRESS=localhost`: Caddy serves
`localhost` with a certificate from its own local CA, which the browser
asks you to accept the first time.

## What `MONK_ENV` changes

Staging and production behave the same; only the log file differs.
Development is the permissive one. Test sides with production where a
test should see the real behaviour (assets, cookies, mail, auth
delivery) and with development where it needs a local default (storage,
Redis, placeholder values).

| | development | test | staging, production |
|---|---|---|---|
| Assets | read from disk on each request, not cached | as production | built into a manifest at boot; `?v=` stamped URLs cached for a year |
| Cookies | not `Secure`, so plain http works | `Secure` | `Secure` |
| Logging | `log/development.log`, and each request echoed to stdout | `log/test.log` | `log/staging.log` or `log/production.log` |
| Mail without `MAIL_URL` | printed to stdout | raises (`.env.test` sets `log://`) | raises |
| Magic link without `deliver:` | printed, with a QR code | raises | raises |
| Storage URL and secret | defaults (`file://storage/<env>`) | defaults | required; an `http://` endpoint is refused |
| `REDIS_URL` | defaults to localhost | defaults to localhost | required |
| Push contact on a placeholder host | warns | warns | raises |
| `LIVE_WS_URL` default | `ws://localhost:9293`, the WebSocket process directly | `PUBLIC_URL` + `/ws` | `PUBLIC_URL` + `/ws`, through the proxy |
| Live demo route | on | off | off |
| [Values refused at boot](#values-refused-at-boot) | only an origin's shape | only an origin's shape | all |
| `Jobs.clear!`, `Jobs.run_scheduler!`, `Auth.clear_login_requests!` | refused | allowed | refused |

`monk new` scaffolds ship a `config/settings.rb`, required first by `config/load.rb` (before every other config and `app/`), that loads `.env` through `dotenv`, which every scaffolded `Gemfile` includes: the modules `monk add` adds write their settings there (see [`scaffolding.md`](scaffolding.md)). A missing `.env` file, or the gem not being bundled at all, is a harmless no-op either way; production deploys get their env vars from the hosting platform, not this file.
