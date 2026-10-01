# Scaffolding a new project — `monk new`

```
monk new my_app              # Gemfile, config.ru, config/load.rb, config/settings.rb, app/app.rb,
                              #   app/views/, every app/ role directory (below), .ruby-version,
                              #   Dockerfile, .dockerignore, bin/server, bin/websocket_server, public/,
                              #   SETUP.md -- config/settings.rb declares public_url (this app's own
                              #   origin, read by auth/live below)
monk new my_app --postgres   # + config/persistence.rb, bin/console, bin/setup_db, bin/migrate, db/migrate/,
                              #   config/load.rb wired to require it, .env/.env.test/.env.example,
                              #   Dockerfile swapped for a variant that adds libpq (the pg gem's native ext)
monk new my_app --auth       # + --postgres, above, plus config/auth.rb, app/mailers/app_mailer.rb
                              #   (the magic-link sender) and a migration for login_tokens/sessions
                              #   (config/load.rb requires config/auth instead of config/persistence;
                              #   .env/.env.test/.env.example get a placeholder AUTH_SECRET), and
                              #   --mail, below, to send the magic link (+ app/views/mail/magic_link.erb)
monk new my_app --mail       # + Monk::Mail, no Postgres needed: config/mail.rb (config/load.rb requires it),
                              #   the net-smtp gem, MAIL_FROM in .env files, MAIL_URL=log:// in .env.test
monk new my_app --redis      # + the redis gem, for bin/websocket_server's cross-process
                              #   fan-out; writes/extends .env/.env.example with a placeholder
                              #   REDIS_URL either way, whether or not --postgres is also set
monk new my_app --live --redis     # + a Monk::Live demo (a counter whose open tabs update together):
                                    #   config/live.rb (Redis-based), app/views/live/, the browser
                                    #   runtime under public/js/monk_live/, and live versions of
                                    #   app/app.rb, app/views/index.erb and bin/websocket_server
monk new my_app --live --postgres  # same demo, but config/live.rb uses Monk::WebSocket::PgFanout
                                    #   (Postgres LISTEN/NOTIFY) instead -- no redis gem, no REDIS_URL.
                                    #   --live requires --redis or --postgres explicitly (raises
                                    #   Monk::AmbiguousLiveTransportError with neither -- see live.md,
                                    #   "Without Redis"); passing both picks --redis
monk new my_app --jobs       # + Monk::Jobs, background jobs, and --postgres, where the queue lives:
                              #   config/jobs.rb (config/load.rb requires it), app/jobs/hello_job.rb and a
                              #   POST /jobs/hello route enqueueing it, bin/jobs (the job process),
                              #   the migration for the queue's tables, JOBS_WORKERS/JOBS_QUEUES in
                              #   .env/.env.example. With --mail (or --auth): config/jobs.rb loads
                              #   Monk::Mail.deliver_later, and JOBS_QUEUES serves "mailers" first.
                              #   With --auth: app/jobs/send_login_link.rb, which sends magic links from a job
```

## How flags combine

A flag is **implied** when there's only one right answer, and **required**
when there's a real choice:

| Flag | Implies | Requires |
|---|---|---|
| `--auth` | `--postgres` (Auth only runs on Postgres), `--mail` (a magic link has to reach someone) | — |
| `--jobs` | `--postgres` (the queue lives there) | — |
| `--live` | — | `--redis` or `--postgres`: Live's cross-process transport is a choice with trade-offs, so Monk won't pick it for you, and raises `Monk::AmbiguousLiveTransportError` with neither |
| `--postgres`, `--mail`, `--redis` | — | — |

Some pairs also change what gets generated:

| Together | Generates |
|---|---|
| `--auth` + `--jobs` | `app/jobs/send_login_link.rb`: login links are sent from a job, and the raw token is never stored |
| `--mail` + `--jobs` | `config/jobs.rb` loads `Monk::Mail.deliver_later`, and `JOBS_QUEUES` serves `mailers` first |
| `--live` + `--redis` | `config/live.rb` fans out over Redis (`--redis` wins if `--postgres` is also on) |
| `--live` + `--postgres` | `config/live.rb` fans out over Postgres (`Monk::WebSocket::PgFanout`) |

A flag counts whether you typed it or another flag implied it: `monk new
my_app --auth --live` gets Postgres fan-out, because `--auth` turned
`--postgres` on. `monk new` prints the outcome after creating the
project:

```
Flags: --auth --jobs --live, which also turned on:
  --postgres  (needed by --auth, --jobs)
  --mail      (needed by --auth)
Together they also generate:
  --auth + --jobs      app/jobs/send_login_link.rb: login links are sent from a job
  --mail + --jobs      config/jobs.rb loads Monk::Mail.deliver_later; JOBS_QUEUES serves mailers first
  --live + --postgres  config/live.rb fans out over Postgres (Monk::WebSocket::PgFanout)
```

## What gets written

Writes a fresh project directory from static templates (never overwrites
an existing directory — `monk new` refuses if `my_app` already exists) and
prints the next manual step (`bundle install`); it never runs `bundle
install`, `git init`, or anything else on your behalf.

Every app has the same layout (ADR 0015 records why). Every flag set
produces this tree; flags only add files to it:

```
config.ru              # require_relative "config/load"; require_relative "app/app"; run Monk.boot(App)
config/
  load.rb              # every enabled config, then app/ by role
  settings.rb          # + persistence.rb auth.rb mail.rb jobs.rb live.rb, one per enabled Monk module
app/
  app.rb               # class App < Monk::Base and its routes
  models/  presenters/  helpers/  mailers/  broadcasts/  jobs/   # each with a .keep
  views/               # layouts/, and mail/ or live/ when a flag adds templates there
db/migrate/  public/  bin/  test/
```

`config.ru` is the same three lines for every flag set. `config/load.rb`
is where the flags differ: it requires `config/settings`, then each
enabled module's config (`persistence` or `auth`, then `mail`, `jobs`,
`live`), then loads `app/`. It never boots the app — `config.ru`'s
`Monk.boot(App)` does. `bin/jobs`, `bin/console` and the test helper
require `config/load` too, so they see the same configs, models, mailers
and jobs as `bin/server`. `bin/websocket_server`, `bin/migrate` and
`bin/setup_db` keep their own short lists of configs, since they need no
app code.

### Where code goes

`app/` has one directory per role: what the rest of the app calls that
code for, whatever its base class. Every role directory is created,
even when empty, so the tree shows where each kind of code goes:

| Directory | The rest of the app calls it to | For example |
|---|---|---|
| `app/models/` | read and change the app's data, and apply the rules on it | a `Monk::Persistence::Pg::Model`, a `Data` with queries, a module of SQL |
| `app/presenters/` | get data ready for a page or partial, from models | the rows a sidebar shows |
| `app/helpers/` | call a method directly from any route or template | a module that does `Monk::Context.include(self)` |
| `app/mailers/` | send an email: subject, text, a `app/views/mail/` template | `AppMailer::MAGIC_LINK` |
| `app/broadcasts/` | push a change to open pages (`Monk::Live.patch`/`batch`) | the patches sent when a message arrives |
| `app/jobs/` | run work later, in `bin/jobs` (`Monk::Job` subclasses) | `HelloJob` |
| `app/views/` | render HTML (`.erb` only) | every template |

- **Routes** stay in `app/app.rb`. An app with many can reopen `class App`
  in more files (say `app/routes/*.rb`) and require them from `app/app.rb`.
- **A presenter or a helper?** A route calls a presenter by name
  (`Sidebar.rows(user)`) and passes what it returns to a template. A
  helper is a module mixed into every request's `Monk::Context`, so routes
  and templates call its methods directly (`avatar(person)`). `helpers/`
  holds only such modules.
- **No catch-alls.** Code that fits none of the roles gets a new role
  directory, named the same way (a plural noun saying what it's for), not
  `services/` or `utils/`. Code that isn't specific to this app at all
  goes in `lib/`.
- **Templates only in `app/views/`**, grouped by what renders them:
  `app/views/mail/` for mailers, a partials directory for broadcasts and
  pages. `Monk::Views` compiles one root, so `.rb` files don't go there
  and `.erb` files don't go anywhere else.
- **A module whose flag is off.** `app/jobs/`, `app/mailers/` and
  `app/broadcasts/` exist without `--jobs`, `--mail` or `--live`. A file
  added there fails at load with `uninitialized constant Monk::Job` (or
  `Monk::Mail`, `Monk::Live`) until the module is enabled: add its
  `require` and config, as in "Adding ... to an existing app" below.
- **Deleting a directory** you don't want is fine; `config/load.rb`
  skips missing ones.

### Load order

`config/load.rb` loads, after the configs, `models`, `presenters`,
`helpers`, `mailers`, `broadcasts`, `jobs`, each directory as a sorted
glob. Everything is loaded before `Monk.boot` freezes the app, since
nothing can be loaded later from a worker Ractor; there's no autoloading.

The order matters less than it looks. A constant used inside a method is
looked up when the method runs, after everything is loaded, so a file's
methods may use code from any role, including one loaded after it: a
model's method can enqueue a job, a mailer can read the models loaded
before it. Only code that runs while the file loads needs what it uses
loaded first: a superclass, a constant used in a class body, a
`Monk::Context.include`. Such a file does `require_relative` on the file
it depends on (requiring a file twice is harmless).

A config that needs app code requires the specific files it needs,
because configs load before `app/`, and some are loaded without
`config/load.rb` (`bin/websocket_server` loads `config/auth.rb` and
`config/live.rb` on their own). `config/auth.rb` does
`require_relative "../app/mailers/app_mailer"` for its `deliver:`, and a
`config/live.rb` whose subscribe rule calls a model does the same for
that model.

### SETUP.md

Every flag combination — including the plain base skeleton — gets a
`SETUP.md`, tailored to exactly what was scaffolded: dev setup (nothing
external for the base skeleton; a reachable Redis under `--redis`;
starting/reusing Postgres/Redis containers, creating the database,
running migrations under `--postgres`) and then test setup, since
`monk new` doesn't scaffold a test framework itself. The test setup is
the minimum Minitest wiring: a `Rakefile`, a `test/test_helper.rb` that
loads the app the way `config.ru` does (`config/load`, `app/app`) and
boots it once as `APP`, a `test/app_test.rb` that requests `/hello`
through it, and, per flag, a real Postgres connection test and a
`Monk::Jobs.drain!` test.

`--postgres` and/or `--redis` write `.env` and a tracked `.env.example`
(`.env.test` too, but only when something needs it: `--postgres`, `--mail`,
or `--live --redis`), with `DB_NAME` defaulting to
`APP_NAME_development`/`APP_NAME_test` rather than the generic
`app_development` fallback baked into `config/persistence.rb`'s own
`ENV.fetch`. `--auth` adds a placeholder `AUTH_SECRET` to all three env
files (change it before relying on it); `--redis` adds a placeholder
`REDIS_URL` to `.env`/`.env.example` only — not `.env.test`, since only
a test that actually exercises `RedisFanout` needs it — the same whether
or not `--postgres` is also set. `--live --redis` is the exception: the
test helper loads `config/live.rb`, which needs `REDIS_URL`, so
`.env.test` gets it too. Building the fanout connects to nothing, so the
tests still need no Redis running unless one publishes. Either flag also uncomments
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
(see the flag list above). It calls `REGISTRY.listen!` at boot (the
`--live` version calls `Monk::Live.listen!`): it's the only process that
listens for broadcasts from other processes, see
[`websocket.md`](websocket.md). `--redis` is fully independent,
and doesn't imply or get implied by `--postgres`/`--auth`.

`--jobs` implies `--postgres` and nothing else. `bin/jobs` is the job
process, run beside `bin/server` (and `bin/websocket_server`, if the app
uses it). It requires `config/load`, so jobs see every config and all of
`app/`: they can use models, send mail, and with `--live` push Live
updates (without listening; only `bin/websocket_server` does). `SETUP.md`
shows it running the demo job, and its test section adds a sample test
that runs jobs with `Monk::Jobs.drain!`. See [`jobs.md`](jobs.md).

With `--mail` (or `--auth`, which implies it), `--jobs` also adds
`require "monk/mail/later"` to `config/jobs.rb`, so
`Monk::Mail.deliver_later` is available, and sets
`JOBS_QUEUES=mailers,default`, so emails go out before other work. With
`--auth` it adds `app/jobs/send_login_link.rb`: your login route enqueues
it, and it creates the login token and sends the link inside the job, so
the raw token is never stored in the queue. `config/auth.rb`'s `deliver:`
(`AppMailer::MAGIC_LINK`) stays a synchronous send, which now runs inside
that job. See
[`auth.md`](auth.md#sending-the-magic-link-from-a-job).

The base skeleton's home page is a working HTML page, not a bare JSON
route: a layout and an index template under `app/views/`, and a stylesheet and
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
3. `require_relative "persistence"` in `config/load.rb`, right after
   `require_relative "settings"` — `register` must run, and any `Model`
   classes in `app/models/` load after it, before boot (see
   [`persistence.md`](persistence.md), "Models").
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
   require_relative "../app/mailers/app_mailer" # the deliver: below

   Monk::Auth.configure(
     db_name: :primary, secret: ENV.fetch("AUTH_SECRET"),
     login_ttl: 600, session_ttl: 1_209_600, redirect_allowlist: [],
     secure: !Monk.env.development?,  # see auth.md, "Secure cookies"
     deliver: AppMailer::MAGIC_LINK,
   )
   ```
   `AppMailer::MAGIC_LINK` sends the link, usually through `Monk::Mail`:
   copy `app/mailers/app_mailer.rb` from a `monk new --auth` app, and see
   [`mail.md`](mail.md#with-monkauth) and auth.md, "Sending the magic
   link". The link is built from `Monk::Settings[:public_url]`, already
   declared in every app's `config/settings.rb` (not auth-specific),
   nothing to add here.
2. In `config/load.rb`, replace `require_relative "persistence"` with
   `require_relative "auth"` (it requires `persistence` itself), and add
   `require_relative "mail"` after it once `config/mail.rb` exists.
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
   unset, it runs in-process only, same as without `--redis`. Either way
   it calls `REGISTRY.listen!` before `server.run` (a no-op on a plain
   `Registry`).

**Jobs** (do the Postgres steps first — the queue lives there):

1. Copy from a `monk new --jobs` app, verbatim: `config/jobs.rb`,
   `bin/jobs` (keep it executable), and `app/jobs/hello_job.rb` if you
   want the demo. None of them is templated.
2. `require_relative "jobs"` in `config/load.rb`, after `persistence` (or
   `auth`) and `mail`. `config/load.rb` already loads `app/jobs/`.
3. Add the jobs migration, a copy of the `create_jobs_tables` pair from a
   `monk new --jobs` app, with a version that sorts after the migrations
   you already have (e.g. `20260927120000_create_jobs_tables`), and run it.
4. Run `bin/jobs` beside `bin/server`. `JOBS_WORKERS` and `JOBS_QUEUES`
   set how many workers it runs and which queues they serve.
