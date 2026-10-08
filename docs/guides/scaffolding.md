# Scaffolding: `monk new` and `monk add`

`monk new` writes a bare app. `monk add` adds a Monk module to an app,
new or years old: Postgres, Redis, mail, auth, jobs, WebSocket, Live.
Each module is one generator (ADR 0017): it creates files and appends
lines to the end of a few shared ones (`Gemfile`, the `.env` files,
`.gitignore`, `SETUP.md`, `AGENTS.md`), and never edits or replaces a file
in the middle. So it doesn't matter which modules an app already has, or
the order they were added in.

```bash
monk new shop                        # the bare app
monk new shop --with auth,jobs       # the same, then monk add auth jobs
cd shop
monk add live                        # one more module, any time
monk add --list                      # the modules, and which are installed
```

## `monk new`

`monk new NAME` creates `NAME/` (it refuses a directory that exists) with
the bare app: `app/app.rb` and its views, `config/`, `bin/server`,
`public/`, a `Dockerfile`, the test setup (`Rakefile`,
`test/test_helper.rb`, `test/app_test.rb`), `SETUP.md`, and an
`AGENTS.md` imported by a `CLAUDE.md`. `--with a,b` adds modules in the
same command. It never runs `bundle install`, `git init` or anything else
for you; it prints what to run next.

## `monk add`

`monk add MODULE...`, from the app's directory, adds each module and the
modules it needs, first:

| Module | What it is | Needs |
|---|---|---|
| `postgres` | Postgres persistence and migrations | — |
| `redis` | the app's Redis: a cache, rate limits, or WebSocket's transport | — |
| `mail` | email over SMTP; printed to the console in development | — |
| `auth` | passwordless login by email link | `postgres`, `mail` |
| `jobs` | background jobs on Postgres, run by `bin/jobs` | `postgres` |
| `websocket` | the WebSocket server process | `postgres` or `redis` |
| `live` | HTML pushed to open pages | `websocket` |

- **What it prints:** the files created (`+`), the lines appended (`~`),
  the files it left alone (`!`), the values to set before production, and
  at most three next steps, with the `SETUP.md` section for the rest.
- **Adding a module again** changes nothing, and says so.
- **websocket's transport** carries a broadcast between `bin/server`,
  `bin/jobs` and `bin/websocket_server`. `--transport=postgres` or
  `--transport=redis` chooses it, and adds that module if it's missing.
  With exactly one of the two installed, or added in the same command,
  it's inferred. Otherwise `monk add` asks in a terminal, and anywhere
  else stops with exit code 2, naming the flag. `live` uses websocket's
  transport. Switching later is three steps in `SETUP.md`, websocket.
- **live's demo** (`/demo/live`, development only) comes by default;
  `--no-demo` leaves it out.
- **`--dry-run`** prints the same report and writes nothing.
- **A file the app already has**, with other content: if the module needs
  it to run (a config, a `bin/` script, a migration, a file a config
  requires), nothing at all is written and `monk add` exits with 3. Any
  other file (an example, a test, a view, the demo) is left as it is, the
  rest is added, and `monk help MODULE --file PATH` prints Monk's version.
- **Migrations** get the time they're added as their version
  (`db/migrate/20261008143000_create_jobs_tables.up.sql`). The migrator
  applies whatever isn't applied yet, so a module added to an older app
  migrates normally: run `bin/setup_db`.

`monk help MODULE` lists what a module writes, its options, and what it
needs.

## The modules

Each module writes three kinds of code. **Wiring** runs as soon as it's
added. **Examples** are the code an app writes to use the module, commented
out where that code goes (below). **A test** in `test/` proves the wiring:
`bundle exec rake test` runs it.

- **postgres:** `config/persistence.rb` (the `:primary` connection, from
  `DB_*`, with database names taken from the app's directory),
  `bin/setup_db`, `bin/migrate`, `bin/console`, `db/migrate/`; the
  `postgres-model` example (a table, a model, its routes); a test that
  connects. `pg` 1.6+ installs precompiled with its own libpq, so the one
  `Dockerfile` needs no system packages.
- **redis:** `config/redis.rb` (the `redis_url` setting: a local default in
  development and test, required elsewhere); the `redis-cache` example; a
  test that pings.
- **mail:** `config/mail.rb`, `app/mailers/app_mailer.rb` with the
  `mail-welcome` example and its route; `MAIL_URL=log://` for tests; a test
  that delivers to `log/test.log`.
- **auth:** `config/auth.rb`, `app/mailers/auth_mailer.rb` (sends the login
  link), the tables' migration, a login page, and the `auth-routes`
  example: request a link (with a rate limit), the callback, logout, a page
  for logged-in users. The routes stay commented until you've decided on
  their limits; `AGENTS.md` says why. A test sends a link and redeems it.
- **jobs:** `config/jobs.rb`, `bin/jobs`, the queue's migration, the demo
  `HelloJob` and the `jobs-enqueue` example; a test that enqueues and
  drains. With mail installed, `Monk::Mail.deliver_later` exists; with
  auth, `Monk::Auth::SendLoginLink`.
- **websocket:** `config/websocket.rb` (`AppWebSocket::REGISTRY`, over the
  transport), `bin/websocket_server`, and the `websocket-chat` example in
  `app/sockets/`; a test that sends a broadcast across the transport.
- **live:** `config/live.rb` (Live on websocket's registry, the
  `live-rule` example), the `live-broadcast` example, the demo; a test that
  an update reaches a subscribed socket. The layout's `<%= monk_head %>`
  loads the browser client, which Monk serves from the gem.

## Examples

Each example is a block of commented code, tagged:

```ruby
# monk:example auth-routes -- log in by email link, log out, a page for logged-in users.
# # Before going live: keep a rate limit ...
# class App
#   post("/auth/request") do
#     ...
# end
# monk:end
```

Lines starting `# # ` are notes, which stay comments; the others are code.
To use one, uncomment it (remove one `# ` from each line between the two
markers) and adapt it. `grep -rn "monk:example" app config` lists them.
Monk's own tests uncomment every example in a generated app and run it,
so they keep working as Monk changes.

## What every app looks like

Every app has the same layout (ADR 0015 records why); modules only add
files to it:

```
config.ru              # require_relative "config/load"; require_relative "app/app"; run Monk.boot(App)
config/
  settings.rb          # the app's settings; loads .env
  load.rb              # every module's config that exists, then app/ by role
  persistence.rb redis.rb auth.rb mail.rb jobs.rb websocket.rb live.rb   # one per module added
app/
  app.rb               # class App < Monk::Base, its base routes; loads app/routes/*.rb
  routes/              # more routes, one file per module or feature, each reopening class App
  models/  presenters/  helpers/  mailers/  broadcasts/  jobs/   # each with a .keep
  views/               # layouts/, and mail/, live/, auth/ as modules add templates
  sockets/             # with websocket: socket handlers, when the app doesn't use live
db/migrate/  public/  bin/  test/
SETUP.md  AGENTS.md  CLAUDE.md
```

`config.ru` is the same for every app. `config/load.rb` is too: it
requires `config/settings`, then each module's config that exists, in a
fixed order (`persistence redis auth mail jobs websocket live storage`),
then loads `app/`. It never boots the app; `config.ru`'s `Monk.boot(App)`
does. `bin/jobs`, `bin/console` and the test helper require `config/load`
too, so they see the same configs, models, mailers and jobs as
`bin/server`. `bin/websocket_server`, `bin/migrate` and `bin/setup_db`
load only the configs they need.

### Where code goes

`app/` has one directory per role: what the rest of the app calls that
code for, whatever its base class. Every role directory is created, even
when empty, so the tree shows where each kind of code goes:

| Directory | The rest of the app calls it to | For example |
|---|---|---|
| `app/models/` | read and change the app's data, and apply the rules on it | a `Monk::Persistence::Pg::Model`, a `Data` with queries, a module of SQL |
| `app/presenters/` | get data ready for a page or partial, from models | the rows a sidebar shows |
| `app/helpers/` | call a method directly from any route or template | a module that does `Monk::Context.include(self)` |
| `app/mailers/` | send an email: subject, text, an `app/views/mail/` template | `AppMailer.welcome`, `AuthMailer::MAGIC_LINK` |
| `app/broadcasts/` | push a change to open pages (`Monk::Live.patch`/`batch`) | the patches sent when a message arrives |
| `app/jobs/` | run work later, in `bin/jobs` (`Monk::Job` subclasses) | `HelloJob` |
| `app/views/` | render HTML (`.erb` only) | every template |

- **Routes:** `app/app.rb` holds `class App` and its base routes, and
  loads every file in `app/routes/` (sorted), each reopening `class App`.
  Modules put their routes there (`app/routes/auth.rb`), and so can you.
  Never put a route in another role's directory: `config/load.rb` loads
  those before `app/app.rb` defines `App`.
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
- **A module not added yet.** `app/jobs/`, `app/mailers/` and
  `app/broadcasts/` exist without jobs, mail or live. A file added there
  fails at load with `uninitialized constant Monk::Job` (or `Monk::Mail`,
  `Monk::Live`) until you `monk add` the module.
- **Deleting a directory** you don't want is fine; `config/load.rb`
  skips missing ones.

### Load order

`config/load.rb` loads, after the configs, `models`, `presenters`,
`helpers`, `mailers`, `broadcasts`, `jobs`, each directory as a sorted
glob; `app/app.rb` then loads `app/routes/`. Everything is loaded before
`Monk.boot` freezes the app, since nothing can be loaded later from a
worker Ractor; there's no autoloading.

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
`require_relative "../app/mailers/auth_mailer"` for its `deliver:`, and a
`config/live.rb` whose subscribe rule calls a model does the same for
that model.

## SETUP.md and AGENTS.md

`monk new` writes both, and each module appends its own section, headed
with its name (`## jobs`), so `SETUP.md#jobs` links to it:

- **`SETUP.md`** is for getting the app running once: the services a
  module needs, how to start them (including the Docker command, named
  after the app), the databases to create, how to check it works.
- **`AGENTS.md`** is the reference for working on the app, for people and
  coding agents alike (`CLAUDE.md` imports it): the layout, the commands,
  the rules that break the app if ignored, and for each module where its
  code goes, its main calls, its test, its pitfalls and its examples.

## For agents and scripts: `--json` and exit codes

Every command takes `--json` and then prints one JSON object, never
prompting: what was added and why (`modules`), every file with its role
and what happened to it (`files`, `skipped`), the env vars that need a real
value (`env`), the examples with their file and line (`examples`), the
services the next steps need and a command checking each one runs
(`services`), the next steps in order (`next`), and the `SETUP.md` and
`AGENTS.md` sections to read (`docs`). An error has `message`, and a
`suggestion`, `choice` or `conflicts` where they apply.
`monk add --list --json` lists the modules, which are installed, and what
each needs.

| Exit code | Meaning |
|---|---|
| 0 | done, including "already installed" and files left as they were |
| 1 | a usage error: an unknown module or option, one of `monk new`'s old module flags |
| 2 | a choice is missing (`--transport`) |
| 3 | a file the module needs exists and differs; nothing was written |
