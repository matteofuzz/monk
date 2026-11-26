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

## 0.28.2

`bundle update monkrb`.

### Never cache the download route (apps with storage)

Each route that redirects to `Monk::Storage.url` sets `no-store` first,
so neither its 404 nor its redirect is cached; only the signed link's
bytes are ([`storage.md`](storage.md#caching)). If you followed 0.28.1's
step, this replaces its `private, max-age=` line:

```ruby
get("/media/:id") do
  headers["cache-control"] = "no-store"
  # ... the access check, halt 404 ...
  redirect Monk::Storage.url(key), allow_other_host: true
end
```

A cached redirect failed in an iPhone app installed on the Home Screen,
and a cached 404 can hide a file uploaded after it. If the app
overwrites files in place (an avatar under `avatars/<user>`, say), give
each new version a new key and point the record at it: the bytes stay
cached under the old link up to `expires_in`.

## 0.28.1

`bundle update monkrb`. S3 download links are then cached by the
browser for `expires_in` (an hour by default), with nothing to change.

### Cache the download redirect: replaced by 0.28.2

0.28.1 recommended `cache-control: private, max-age=<expires_in>` on
the download redirect. Don't add it: follow 0.28.2's step instead.

## 0.28

In the `Gemfile`, `gem "monkrb", "~> 0.28", require: "monk"` (what a new
app gets; `"~> 0.27"` would also install 0.28, but not require it), then
`bundle update monkrb`. The steps below are for apps with auth, and one
for apps with pwa.

### `request_login` returns a Hash (apps with auth)

`Monk::Auth.request_login` now returns `{ token:, code: }` instead of the
token: the sign-in code is made beside the link
([`auth.md`](auth.md#signing-in-with-a-code)). Wherever the app calls it,
take the token with `[:token]`:

```ruby
login = Monk::Auth.request_login(email)
Monk::Auth.deliver_link(email: email, link: Monk::Auth.login_link(login[:token]), token: login[:token],
  code: login[:code])
```

`Monk::Auth::SendLoginLink` already does. In tests,
`Monk::Auth.redeem(Monk::Auth.request_login(email)[:token])`.

### `deliver:` gets two more keywords (apps with auth)

`deliver:` is now called with `redirect_to:` and `code:` too. A lambda
taking only `email:, link:, token:` raises `ArgumentError`: add them, or
`**` (`lambda do |email:, link:, **|`). To send the code, take the new
`app/mailers/auth_mailer.rb` and `app/views/mail/magic_link.erb` (`monk
help auth --file app/mailers/auth_mailer.rb`, run in the app, shows it
with the app's name): the subject starts with the code.

### The migration (apps with auth)

Copy `db/migrate/x_add_login_codes.{up,down}.sql` (`monk help auth
--file db/migrate/x_add_login_codes.up.sql`) under a new timestamp, and
run `bin/migrate`. It adds the code's columns to `login_tokens` and
`login_requests`, and an index on `login_tokens (email, created_at)`.

### The login page and routes (apps with auth)

To sign in with the code, take the new `app/views/auth/login.erb`, and
from the `auth-routes` block of `app/routes/auth.rb` (`monk help auth
--file app/routes/auth.rb`): the `/auth/request` route (it sets `@email`,
which shows the code form), and the new `POST /auth/code` and
`POST /auth/own` (the installed iPhone app's own session,
[`auth.md`](auth.md#the-installed-iphone-apps-own-session)).

### What changes by itself (apps with auth)

- **Addresses are stripped and downcased** in `request_login`, so a
  session's subject is too. Sessions made before keep their subject as it
  was.
- **Sessions are renewed by use**: a person who keeps using the app
  stays signed in. `session_max_age:` caps a session's whole life, if
  you want one.
- **Expired sessions are kept 90 days** (`expired_retention:`) before
  `Monk::Auth.sweep!` deletes them, and web push keeps reaching them
  until then. `expired_retention: 0` deletes them when they expire, as
  before.
- **`redirect_allowlist` takes Regexps** too, and an allowed path may
  carry a query string.

### Helping people install (optional, apps with pwa)

Add `<%= monk_install %>` to `app/views/layouts/app.erb` for an install
banner, and style its `monk-install` classes
([`pwa.md`](pwa.md#helping-people-install)).

## 0.27

In the `Gemfile`, `gem "monkrb", "~> 0.27", require: "monk"` (what a new
app gets; `"~> 0.26"` would also install 0.27, but not require it), then
`bundle update monkrb`.

Boot now refuses some settings that are present but wrong
([`settings.md`](settings.md#values-refused-at-boot)). Check them before
deploying, and in CI if it boots the app as staging or production:

- **`PUBLIC_URL`**: no trailing slash or path, anywhere. In staging and
  production, `https://` and the real host, not a placeholder like
  `app.example.com`.
- **`LIVE_WS_URL`**, if set: `wss://` in staging and production.
- **`AUTH_SECRET`** in staging and production: at least 32 characters,
  without `change-me`. Make one with `openssl rand -hex 32`. A new secret
  signs everybody out.

With websocket, `WS_ALLOWED_ORIGINS` now lists only the origins allowed
besides `PUBLIC_URL`. A new app's `bin/websocket_server` always allows
`PUBLIC_URL`; in an existing one, replace the `allowed_origins = ...`
line with the one from `monk help websocket --file bin/websocket_server`,
then drop `PUBLIC_URL` from `WS_ALLOWED_ORIGINS` (leaving it is harmless).

## 0.26

In the `Gemfile`, `gem "monkrb", "~> 0.26", require: "monk"` (what a new
app gets; `"~> 0.25"` would also install 0.26, but not require it), then
`bundle update monkrb`. Most of 0.26 needs nothing from an app, but four
changes can turn a request that worked into an error. Check each against
your routes first.

### Check your routes

- **Redirects to another host.** `redirect` now goes only to this app (a
  path, or a URL on the request's `Host`) and raises
  `Monk::UnsafeRedirectError` for anything else. Add
  `allow_other_host: true` where the app builds the location itself and
  means it: the storage download route an earlier `monk add storage`
  wrote (`redirect Monk::Storage.url(...)`), a payment provider's
  checkout, an OAuth authorize URL. Never add it to a location taken
  from `params`.
- **Browser requests from other sites.** A POST, PUT, PATCH or DELETE a
  browser sends from another site now gets a 403. Requests without
  `Sec-Fetch-Site` or `Origin` (curl, a server's webhook) still pass. A
  route that must accept another site's browser requests (a form on a
  partner's site, a cross-origin `fetch` you allow with CORS) needs
  `allow_cross_origin: true`: `post("/hook", allow_cross_origin: true)`.
- **Request bodies.** A JSON body over 1 MB is a 413. Malformed JSON, or
  JSON that isn't an object, is a 400, where it used to arrive as empty
  `params`. A `multipart/form-data` body is a 415.
- **Response headers.** Every response carries `x-content-type-options:
  nosniff`, `content-security-policy: frame-ancestors 'none'` and
  `referrer-policy: strict-origin-when-cross-origin`. For a page another
  site may show in a frame, set `content-security-policy` on that route.
  If the app sets its own `content-security-policy`, it replaces Monk's,
  so include `frame-ancestors` in it.

Also: a route that sets `self.status` and returns a body now sends that
status, where it used to send 200.

### Forms (optional)

Plain HTML forms work now ([`forms.md`](forms.md)). To use what a new
app has, carrying over anything you changed in yours:

- `app/views/layouts/app.erb` shows the flash message
  (`monk help base --file app/views/layouts/app.erb`).
- With auth: the login page is a plain form, with no script
  (`monk help auth --file app/views/auth/login.erb` and
  `--file app/routes/auth.rb`). The old page keeps working.
- `AGENTS.md`: the base section's new `## Forms` part, and the cross-site
  and redirect rules, tell an app's agents how to write forms. They're in
  the gem at `lib/monk/templates/base/agents.md`
  (`gem contents monkrb | grep templates/base/agents.md`).

### Deploying with Docker Compose (optional)

`monk add deploy` is new ([`deploying.md`](deploying.md), section 4;
[`deploy-hetzner.md`](deploy-hetzner.md)). It counts as installed when
`compose.yaml` exists, so an app with a hand-written one should move it
aside first, run `monk add deploy`, then carry over what it needs.
Keep `services:` the last key of the new file, since modules append
there. A `.env.production` you already have keeps working: compare it
with the new `.env.production.example`, which uses Compose's service
names (`DB_HOST=postgres`).

### Presence

No change to make. A page whose socket closes now reads away during the
grace, then offline, instead of keeping its last status. So an
`on_change` hook sees online, away, offline where it used to see online,
offline. A process stopping on a deploy still keeps everyone's status.

## 0.25

In the `Gemfile`, `gem "monkrb", "~> 0.25", require: "monk"` (what a new
app gets; `"~> 0.24"` would also install 0.25, but not require it), then
`bundle update monkrb`. Both modules below are optional; an app that adds
neither needs none of this.

### Installable app (optional)

`monk add pwa` is new ([`pwa.md`](pwa.md)). First add `pwa` to the list
of module configs in `config/load.rb`, after `storage`
(`monk help base --file config/load.rb`). Then `monk add pwa`, set the
name in `public/manifest.webmanifest`, and replace the icons.

### Web push (optional, apps with auth and jobs)

`monk add push` is new ([`push.md`](push.md)); it adds `pwa` too.
Before running it, update two files an earlier Monk wrote, carrying over
anything you changed in yours:

- `config/load.rb`: `pwa push` at the end of the list of module configs.
- `config/recurring.rb`: the `monk_push_sweep` line, after
  `monk_auth_sweep` (`monk help jobs --file config/recurring.rb`).
- `JOBS_QUEUES`, in `.env` and wherever `bin/jobs` runs: add `push`
  (`mailers,push,default`). Notifications are sent from the `push` queue;
  without it they wait there, unsent.

Then `monk add push`, `bin/setup_db`, and restart `bin/server` and
`bin/jobs`. In production, set `VAPID_PUBLIC_KEY` and
`VAPID_PRIVATE_KEY` (from `monk push keys`); the contact is
`PUBLIC_URL` unless `VAPID_CONTACT` is set.

## 0.24

In the `Gemfile`, `gem "monkrb", "~> 0.24", require: "monk"` (what a new
app gets; `"~> 0.23"` would also install 0.24, but not require it), then
`bundle update monkrb`.

### `ping_interval:` in `bin/websocket_server` (apps with websocket)

`ping_interval:` now also closes a connection that sends nothing, not
even a pong, for two intervals, and must be at least 5 s. Add
`ping_interval: 25` to the `Monk::WebSocket::Server.new(...)` call in
`bin/websocket_server` (`monk help websocket --file bin/websocket_server`
shows where), so a quiet page survives a proxy's idle timeout and a
socket whose peer vanished is closed after 50 s instead of held. If your
app already sets one under 5, raise it: `Server.new` refuses it at boot.

### Presence (optional, apps with auth and websocket)

`monk add presence` is new ([`presence.md`](presence.md)). It writes its
own files, but three files an earlier Monk wrote don't know about it yet.
Before running it, update them from this Monk's versions, carrying over
anything you changed in yours:

- `config/load.rb`: `presence` in the list of module configs, after
  `live` (`monk help base --file config/load.rb`).
- `config.ru`: `Monk.boot(App)` assigned to `app`, then
  `Monk::Presence.start_reactor! if defined?(Monk::Presence) && Monk::Presence.configured?`,
  then `run app` (`monk help base --file config.ru`).
- `bin/websocket_server`: `presence` loaded beside `auth` and `live`,
  `Monk::Presence.start!` before the server, `presence:` passed to it, and
  `Monk::Presence.stop!` when it stops
  (`monk help websocket --file bin/websocket_server`).

Then `monk add presence`, `bin/setup_db`, and restart `bin/server` and
`bin/websocket_server`. An app that doesn't add presence needs none of
this: the lines do nothing without `config/presence.rb`.

## 0.23.1

`bundle update monkrb`. Nothing in the app changes.

## 0.23

In the `Gemfile`, `gem "monkrb", "~> 0.23", require: "monk"` (what a new
app gets; `"~> 0.22"` would also install 0.23, but not require it), then
`bundle update monkrb`.

### `MONK_ENV` in production (every app)

Unset, `MONK_ENV` means development, and a deployed app runs that way
without an error: mail printed instead of sent, magic links logged, demo
routes on. Make sure every deployed process has `MONK_ENV=production` (or
`staging`). A new app's `Dockerfile` sets it; in an existing one, add this
line before `EXPOSE 9292`, or set it in the platform's env:

```dockerfile
ENV MONK_ENV=production
```

`bin/server` now warns when it listens beyond the machine with
`MONK_ENV` unset. To get the warning, copy the file from
`monk help base --file bin/server`; it changes nothing else.

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
