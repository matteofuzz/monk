# Upgrading an app to a new Monk

`monk new` and `monk add` write an app with the current Monk, but they
don't update an app written by an earlier one: `monk add` does nothing
for a module the app already has. So each release that changes what an
app needs lists the steps here: the files to copy, the lines to add, and
the migrations to add.

`monk help MODULE --file PATH` prints this Monk's version of any file a
module writes, so you can copy it or compare it with yours. For a
migration, any timestamp in the name works
(`db/migrate/x_create_recurring_tables.up.sql`): copy it under a new
timestamp of your own, so it runs after your existing migrations.

An app made with the release named in a section needs none of its steps.

## 0.23

In the `Gemfile`, `gem "monkrb", "~> 0.23", require: "monk"` (what a new
app gets; `"~> 0.22"` would also install 0.23, but not require it), then
`bundle update monkrb`. Nothing in an existing app needs to change.

### File storage, if the app wants it

`Monk::Storage` is new. `monk add storage` adds it to an existing app the
same way as to a new one: `config/storage.rb`, the commented upload,
confirm and download examples in `app/routes/storage.rb`,
`test/storage_test.rb`, `/storage/` in `.gitignore` and `.dockerignore`,
and its sections of `SETUP.md` and `AGENTS.md`. It only creates files and
appends lines, so nothing the app already has is touched. Then
[`storage.md`](storage.md) for the bucket, its CORS and lifecycle rules,
and an uploads table to copy.

## 0.22.2

`bundle update monkrb`. Nothing in the app changes.

## 0.22.1

`bundle update monkrb`.

### `bin/websocket_server` (apps with websocket)

`bin/websocket_server` now starts itself with GC settings for many open
sockets ([`websocket.md`](websocket.md#in-a-monk-app-monk-add-websocket)),
and runs `WS_PROCESSES` server processes
([`websocket.md`](websocket.md#several-processes)). Copy the file from
`monk help websocket --file bin/websocket_server`, then carry over
anything you changed in it, or add the new lines yourself:

1. After `require "monk/bin"`:
   ```ruby
   Monk::Bin.boot_with_env!(__FILE__, Monk::Bin::WEBSOCKET_GC_ENV)

   processes = Integer(ENV.fetch("WS_PROCESSES", "1"), exception: false)
   unless processes&.positive?
     abort "bin/websocket_server: WS_PROCESSES must be a whole number, 1 or more, got #{ENV["WS_PROCESSES"].inspect}."
   end
   Monk::Bin.spawn_processes!(__FILE__, processes)
   ```
2. In `Monk::WebSocket::Server.new(...)`, add `reuse_port: processes > 1`.

An app that already sets the `RUBY_GC_HEAP_FREE_SLOTS_*` variables keeps
its values.

## 0.22

First update the gem: in the `Gemfile`, `gem "monkrb", "~> 0.22", require: "monk"`
(what a new app gets; `"~> 0.21"` would also install 0.22, but not
require it), then `bundle update monkrb`.

### Recurring jobs (apps with jobs)

Recurring jobs ([`jobs.md`](jobs.md#recurring-jobs)) need a table and a
file loaded after `app/`. Until the migration is applied, an app that
declares a recurring task can't start `bin/jobs` (it says which migration
is missing), and the app's tests that call `Monk::Jobs.clear!` fail on the
missing table, with or without recurring tasks.

1. **Load `config/recurring.rb`.** Add these lines to `config/load.rb`,
   after the loop that loads `app/` (`monk help base --file config/load.rb`
   shows where):
   ```ruby
   # With jobs (monk add jobs), the schedules of recurring jobs. Last, because
   # each one names a job class from app/jobs/.
   recurring = File.expand_path("recurring.rb", __dir__)
   require recurring if File.exist?(recurring)
   ```
2. **Add `config/recurring.rb`**, where tasks are declared:
   `monk help jobs --file config/recurring.rb > config/recurring.rb`.
3. **Add the migration**, both halves, under a new timestamp, then apply
   it to every database the app uses, the test one included:
   ```bash
   ts=$(date -u +%Y%m%d%H%M%S)
   monk help jobs --file db/migrate/x_create_recurring_tables.up.sql > db/migrate/${ts}_create_recurring_tables.up.sql
   monk help jobs --file db/migrate/x_create_recurring_tables.down.sql > db/migrate/${ts}_create_recurring_tables.down.sql
   bin/migrate && DB_NAME=my_app_test bin/migrate
   ```
   If the queue has a database of its own
   ([`jobs.md`](jobs.md#moving-the-queue-to-its-own-database)), the
   migration goes with the jobs migrations, applied to that database.
4. **Optionally**, the new parts of the jobs sections of `SETUP.md` and
   `AGENTS.md` ("Recurring jobs", and the recurring calls and pitfalls).
   Monk's versions are in the gem, under
   `$(bundle info monkrb --path)/lib/monk/templates/jobs/`: `setup.md` and
   `agents.md`.

### Auth housekeeping (apps with auth)

0.22 adds a login-email rate limit in the database
(`Monk::Auth.allow_login_request?`, [`auth.md`](auth.md#rate-limiting-login-emails)),
an index on `sessions (subject)`, and a nightly cleanup job
([`auth.md`](auth.md#cleaning-up-expired-rows)).

1. **Add the migration**, both halves, under a new timestamp, and apply
   it to every database, the test one included:
   ```bash
   ts=$(date -u +%Y%m%d%H%M%S)
   monk help auth --file db/migrate/x_create_login_requests.up.sql > db/migrate/${ts}_create_login_requests.up.sql
   monk help auth --file db/migrate/x_create_login_requests.down.sql > db/migrate/${ts}_create_login_requests.down.sql
   bin/migrate && DB_NAME=my_app_test bin/migrate
   ```
   Before applying it:
   - If the app already indexes `sessions (subject)` under another name,
     delete the `CREATE INDEX` line (and the `DROP INDEX` line in
     `.down.sql`), or drop your own index afterwards.
   - If the app already has a table called `login_requests`, rename one
     of them first. If yours is a per-address limit with the same columns
     (`email` as primary key, `requested_at`), you can keep its rows: drop
     the `CREATE TABLE` from the migration instead.
2. **Use the rate limit in the login route**, before sending or
   enqueueing the link, in place of the app's own per-email limit:
   ```ruby
   halt(429) unless Monk::Auth.allow_login_request?(email)
   ```
   `monk help auth --file app/routes/auth.rb` shows it in Monk's routes.
3. **In the app's tests that ask for login links**, call
   `Monk::Auth.clear_login_requests!` in `teardown`.
4. **Schedule the cleanup.** With jobs: the `config/recurring.rb` copied
   in "Recurring jobs" above already has this line; if the app had its
   own file, add it:
   ```ruby
   Monk::Jobs.recurring "monk_auth_sweep", Monk::Auth::Sweep, cron: "17 3 * * *" if defined?(Monk::Auth::Sweep)
   ```
   Without jobs, call `Monk::Auth.sweep!` on a schedule of your own. Any
   job the app already has for this can go.
5. **Optionally**, `login_request_interval:` in `config/auth.rb`'s
   `Monk::Auth.configure` (60 seconds when left out), and the new parts of
   the auth sections of `SETUP.md` and `AGENTS.md` (in the gem, under
   `$(bundle info monkrb --path)/lib/monk/templates/auth/`).
