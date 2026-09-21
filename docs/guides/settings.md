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

`monk new` scaffolds ship a `config/settings.rb`, required at the top of `config.ru` before the app class body, that loads `dotenv` if the app's `Gemfile` has it uncommented — the base skeleton ships it commented out, but `--postgres` uncomments it automatically, since that's also what writes a real `.env`/`.env.test` for it to load (see [`scaffolding.md`](scaffolding.md)). A missing `.env` file, or the gem not being bundled at all, is a harmless no-op either way; production deploys get their env vars from the hosting platform, not this file.
