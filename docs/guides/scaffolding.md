# Scaffolding a new project — `monk new`

```
monk new my_app              # Gemfile, config.ru, .ruby-version, Dockerfile, .dockerignore, bin/server,
                              #   bin/websocket_server, views/, public/, SETUP.md -- config/settings.rb
                              #   declares public_url (this app's own origin, read by auth/live below)
monk new my_app --postgres   # + config/persistence.rb, bin/console, bin/setup_db, bin/migrate, db/migrate/,
                              #   config.ru wired to require it, .env/.env.test/.env.example,
                              #   Dockerfile swapped for a variant that adds libpq (the pg gem's native ext)
monk new my_app --auth       # + --postgres, above, plus config/auth.rb and a migration for
                              #   login_tokens/sessions (config.ru requires config/auth instead of
                              #   config/persistence; .env/.env.test/.env.example get a placeholder AUTH_SECRET),
                              #   and --mail, below, to send the magic link (+ views/mail/magic_link.erb)
monk new my_app --mail       # + Monk::Mail, no Postgres needed: config/mail.rb (config.ru requires it),
                              #   the net-smtp gem, MAIL_FROM in .env files, MAIL_URL=log:// in .env.test
monk new my_app --redis      # + the redis gem, for bin/websocket_server's cross-process
                              #   fan-out; writes/extends .env/.env.example with a placeholder
                              #   REDIS_URL either way, whether or not --postgres is also set
monk new my_app --live --redis     # + a Monk::Live demo (a counter whose open tabs update together):
                                    #   config/live.rb (Redis-based), views/live/, the browser runtime
                                    #   under public/js/monk_live/, and live versions of config.ru,
                                    #   views/index.erb and bin/websocket_server
monk new my_app --live --postgres  # same demo, but config/live.rb uses Monk::WebSocket::PgFanout
                                    #   (Postgres LISTEN/NOTIFY) instead -- no redis gem, no REDIS_URL.
                                    #   --live requires --redis or --postgres explicitly (raises
                                    #   Monk::AmbiguousLiveTransportError with neither -- see live.md,
                                    #   "Without Redis"); passing both picks --redis
monk new my_app --jobs       # + Monk::Jobs, background jobs, and --postgres, where the queue lives:
                              #   config/jobs.rb (config.ru requires it), jobs/hello_job.rb and a
                              #   POST /jobs/hello route enqueueing it, bin/jobs (the job process),
                              #   the migration for the queue's tables, JOBS_WORKERS/JOBS_QUEUES in
                              #   .env/.env.example. With --mail (or --auth): config/jobs.rb loads
                              #   Monk::Mail.deliver_later, and JOBS_QUEUES serves "mailers" first.
                              #   With --auth: jobs/send_login_link.rb, which sends magic links from a job
```

Writes a fresh project directory from static templates (never overwrites
an existing directory — `monk new` refuses if `my_app` already exists) and
prints the next manual step (`bundle install`); it never runs `bundle
install`, `git init`, or anything else on your behalf. `--postgres` adds
exactly the persistence/migrations wiring documented above, ready for you
to add your own `db/migrate/*.sql` files and `Model` subclasses.

Every flag combination — including the plain base skeleton — gets a
`SETUP.md`, tailored to exactly what was scaffolded: dev setup (nothing
external for the base skeleton; a reachable Redis under `--redis`;
starting/reusing Postgres/Redis containers, creating the database,
running migrations under `--postgres`) and then test setup, including the
minimum Minitest wiring (`test/test_helper.rb`, a `Rakefile`, one real
smoke test — hitting `Monk::Settings` for the base/`--redis`-only
skeleton, since `config.ru`'s `class App` lives inline in a rackup file
with nothing else standalone-requirable to test yet; a real Postgres
connection under `--postgres`) since `monk new` doesn't scaffold a test
framework itself.

`--postgres` also wires `config.ru` itself — appending
`require_relative "config/persistence"` (or `"config/auth"`, when `--auth`
is set — `config/auth.rb` itself `require_relative`s `persistence`) right
after the settings require, before `class App`.

`--postgres` and/or `--redis` write `.env` and a tracked `.env.example`
(`.env.test` too, but only under `--postgres` — `--redis` alone has
nothing worth putting there, see below), with `DB_NAME` defaulting to
`APP_NAME_development`/`APP_NAME_test` rather than the generic
`app_development` fallback baked into `config/persistence.rb`'s own
`ENV.fetch`. `--auth` adds a placeholder `AUTH_SECRET` to all three env
files (change it before relying on it); `--redis` adds a placeholder
`REDIS_URL` to `.env`/`.env.example` only — deliberately not `.env.test`,
since only a test that actually exercises `RedisFanout` needs it — the
same whether or not `--postgres` is also set. Either flag also uncomments
`gem "dotenv"` in the `Gemfile` — without it, `config/settings.rb`'s
`require "dotenv/load"` never runs, so the `.env` just written would
silently never actually load: `bin/setup_db` would fall back to
`config/persistence.rb`'s own hardcoded `DB_*` defaults, and
`bin/websocket_server` would see no `REDIS_URL` at all and run
in-process only, exactly as if `--redis` had never been passed.

`--auth` always implies `--postgres` — `Monk::Auth` has no path that avoids
Postgres (see [`auth.md`](auth.md)), so there's no flag combination that
scaffolds Auth without also scaffolding persistence underneath it. Plain
`monk new my_app` (no flags) and `--postgres` alone both leave Auth
unconfigured; `require "monk/auth"` still works if you wire it by hand, but
nothing generated by those two commands does it for you.

`bin/websocket_server` is scaffolded unconditionally, unlike Postgres/Redis
— plain `Monk::WebSocket` needs no external service, so there's no infra
reason to gate it behind a flag. The generated script adapts at boot: it
authenticates connections if `config/auth.rb` is present (i.e. the app was
scaffolded with `--auth`, or you wired it up by hand), and wraps its
`Registry` in a `Monk::WebSocket::RedisFanout` instead if `REDIS_URL` is
set — which `--redis` provides via a placeholder in the generated `.env`
(see the flag list above). `--redis` is fully independent,
and doesn't imply or get implied by `--postgres`/`--auth`.

`--jobs` implies `--postgres` and nothing else. `bin/jobs` is the job
process, run beside `bin/server` (and `bin/websocket_server`, if the app
uses it). It loads `config/mail.rb` and `config/auth.rb` when they exist,
so jobs can send mail. `SETUP.md` shows it running the demo job, and its
test section adds `config/jobs` to the test helper and a sample test that
runs jobs with `Monk::Jobs.drain!`. See [`jobs.md`](jobs.md).

With `--mail` (or `--auth`, which implies it), `--jobs` also adds
`require "monk/mail/later"` to `config/jobs.rb`, so
`Monk::Mail.deliver_later` is available, and sets
`JOBS_QUEUES=mailers,default`, so emails go out before other work. With
`--auth` it adds `jobs/send_login_link.rb`: your login route enqueues it,
and it creates the login token and sends the link inside the job, so the
raw token is never stored in the queue. `config/auth.rb`'s `deliver:`
stays a synchronous send, which now runs inside that job. See
[`auth.md`](auth.md#sending-the-magic-link-from-a-job).

The base skeleton's home page is a working HTML page, not a bare JSON
route: a layout and an index template under `views/`, and a stylesheet and
an ES-module entry point under `public/` (see [`views.md`](views.md)). Alongside it, `/hello` and `/api/hello` are two one-line routes
showing the plain-string and `json` response styles side by side.

## Adding Postgres, Auth, Redis or Jobs to an existing app

`monk new`'s flags only apply at creation time — there's no `monk add`
command. Retrofitting an app you already scaffolded plain (or wrote by
hand) means adding the same files `--postgres`/`--auth` would have
written, by hand:

**Postgres:**

1. Add `gem "pg"` to your `Gemfile` (and `gem "irb"` if you want
   `bin/console`), then `bundle install`.
2. Create `config/persistence.rb` — same content as the "Connecting"
   example in [`persistence.md`](persistence.md).
3. `require_relative "config/persistence"` near the top of `config.ru`,
   before `Monk.boot(App)` — `register` and any `Model` classes must exist
   before boot (see [`persistence.md`](persistence.md), "Models").
4. `mkdir -p db/migrate`, and add `bin/setup_db`/`bin/migrate` scripts if
   you want migrations (copy the pattern from [`migrations.md`](migrations.md), or lift
   `bin/setup_db`/`bin/migrate`/`bin/console` verbatim from a
   `monk new --postgres` app — they're plain scripts, not templated).
5. Create the database and register/migrate against it (see "Setting up a
   database" in [`persistence.md`](persistence.md)).

**Auth** (do the Postgres steps first — there's no way around them, see
[`auth.md`](auth.md)):

1. Create `config/auth.rb`:
   ```ruby
   require "monk"
   require "monk/auth"
   require_relative "persistence"

   Monk::Auth.configure(
     db_name: :primary, secret: ENV.fetch("AUTH_SECRET"),
     login_ttl: 600, session_ttl: 1_209_600, redirect_allowlist: [],
     secure: !Monk.env.development?,  # see auth.md, "Secure cookies"
   )
   ```
   Add a `deliver:` callable to send the link, usually through
   `Monk::Mail` — see [`mail.md`](mail.md#with-monkauth) and auth.md,
   "Sending the magic link". The link is built from
   `Monk::Settings[:public_url]`, already declared in every app's
   `config/settings.rb` (not auth-specific), nothing to add here.
2. `require_relative "config/auth"` in `config.ru`, before `Monk.boot(App)`.
3. Add a migration creating `login_tokens`/`sessions` — schema in
   [`design/auth-sessions.md`](../design/auth-sessions.md). Give it a version that sorts after any migrations you
   already have (a timestamp, e.g. `20260907120000_create_auth_tables`) —
   don't reuse `00000000000001`, which `monk new --auth` only picks because
   it assumes it's the first migration in a fresh project.
4. Set `AUTH_SECRET` (e.g. via `.env`, loaded by the `config/settings.rb`
   every skeleton already ships) and run your migration script.

**Redis** (for `bin/websocket_server`'s cross-process fan-out — every app,
scaffolded any way, already has `bin/websocket_server`, since it needs no
flag):

1. Add `gem "redis"` to your `Gemfile`, then `bundle install`.
2. Set `REDIS_URL` (e.g. in `.env`). `bin/websocket_server` reads it
   directly at boot — there's no `config/redis.rb` to add — and wraps its
   `Registry` in a `Monk::WebSocket::RedisFanout` the moment it's present;
   unset, it runs in-process only, same as without `--redis`.

**Jobs** (do the Postgres steps first — the queue lives there):

1. Copy from a `monk new --jobs` app, verbatim: `config/jobs.rb`,
   `bin/jobs` (keep it executable), and `jobs/hello_job.rb` if you want
   the demo. None of them is templated.
2. `require_relative "config/jobs"` in `config.ru`, after
   `config/persistence` (or `config/auth`) and `config/mail`, before
   `Monk.boot(App)`.
3. Add the jobs migration, a copy of the `create_jobs_tables` pair from a
   `monk new --jobs` app, with a version that sorts after the migrations
   you already have (e.g. `20260927120000_create_jobs_tables`), and run it.
4. Run `bin/jobs` beside `bin/server`. `JOBS_WORKERS` and `JOBS_QUEUES`
   set how many workers it runs and which queues they serve.
