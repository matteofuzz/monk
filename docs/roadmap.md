# Roadmap

Features to add, in the order they're planned to ship. Each step is one
release, with the version it's proposed for. Not a commitment: each one
gets its own design doc and plan when work on it starts.

## Releases

1. **0.22: Recurring jobs and auth housekeeping.** Until then, an app that
   prunes old rows on a schedule needs a job that re-enqueues itself.
   - **Scheduled jobs.** Done: `Monk::Jobs.recurring`, declared in
     `config/recurring.rb` and enqueued by `bin/jobs` (ADR 0016,
     `docs/history/plan-scheduled-jobs.md`).
   - **Auth housekeeping.** Done (`docs/history/plan-auth-housekeeping.md`):
     - **Cleaning up `Monk::Auth`'s own tables.** `sessions` and
       `login_tokens` belong to `Monk::Auth`, and expired rows pile up in
       every app, roughly one session a month per active person.
       `Monk::Auth.sweep!` already deletes them; `Monk::Auth` ships it as a
       job, `Monk::Auth::Sweep`, scheduled nightly in the `config/recurring.rb`
       that `monk add jobs` writes: the first real user of recurring jobs.
     - **An index on `sessions (subject)`.** Any app that looks up a
       person's sessions needs it, including `Monk::Auth.revoke_all` and a
       future "log out everywhere". Today each app adds it in its own
       migration; it belongs in Monk's auth schema.
     - **A rate limit on login emails.** `docs/guides/auth.md` leaves "your
       per-email rate limit" to the app, but every app with magic links
       needs one. One table and one upsert: at most one login email per
       address per interval, checked in the login route before the link
       is sent or enqueued. The scaffolded login routes use it instead of
       the per-process `Monk::Auth::RateLimiter`, which stays for other
       limits. A limit across many addresses (per IP, say) stays the app's.
   - **An upgrade guide for 0.21 apps.** `docs/guides/upgrading.md`, one
     section per release from now on: the files to copy and the lines to
     add (`monk help MODULE --file PATH` prints Monk's version), and the
     migrations to add. `monk add` does nothing for a module already
     installed, so this is how an existing app picks up recurring jobs and
     the new auth table and index. Done: the 0.22 section covers both.

2. **0.23: File storage, `Monk::Storage`.** Done (2026-10-26), ahead of
   the releases below, which it was planned after. An opt-in storage
   layer configured by one `STORAGE_URL`: one S3-compatible backend
   (Hetzner, R2, B2, AWS, MinIO) that signs its own SigV4 requests, and
   local files in development and test. Browsers upload straight to the
   bucket through a presigned PUT, downloads go through an app route that
   redirects to a signed link, and `monk add storage` scaffolds it (ADR
   0017). Designed in ADR 0018 (`docs/history/plan-storage.md`,
   `docs/guides/storage.md`). The four items the ADR left open (the
   signed `Content-Length`, CORS for `PUT`, the `tmp/` lifecycle rule and
   same-bucket copy) passed on a real Hetzner bucket.

3. **0.24: Live on real networks, and presence.** For apps that show
   whether a person is online, on mobile browsers as well as desktop ones.
   Done (2026-11-13), measured on desktop, iPhone and Android
   (`docs/plan-live-networks-presence.md`). A few device checks on a
   deployed app are still open there; they run on the first real deploy.
   - **Mobile.** Done: with `ping_interval:`, the WebSocket server closes a
     connection silent for two intervals. The Live client pings while its
     page is visible, gives up on a socket silent for 10 s, and reconnects
     and resyncs when the page is shown, comes back online or is restored
     from the back/forward cache.
   - **Presence: is this person connected?** Done: `Monk::Presence`
     (`monk add presence`, `docs/guides/presence.md`). Each WebSocket
     process keeps its rows in the app's Postgres, a dead process's rows
     expire, and `bin/server` calls the app's `on_change` once per
     transition (online, away, offline). It's tied to Live, which tells it
     whether each page is visible (ADR 0019).

4. **0.25: PWA and web push.** Together because on iOS web push needs the
   app installed on the Home Screen. Built (`docs/plan-pwa-push.md`); the
   checks on real devices are still open there.
   - **PWA scaffolding.** Done: `monk add pwa` (`docs/guides/pwa.md`): a
     web app manifest and a `sw.js` served at the root scope, checked at
     boot, with no `fetch` handler, so it never gets in the way of the
     Live client.
   - **Web push, `Monk::Push`.** Done: `monk add push`
     (`docs/guides/push.md`, ADR 0020): VAPID keys, subscriptions tied to
     auth sessions, sending from a job per device, and deleting
     subscriptions the push service reports as gone (404/410).

5. **0.26: `monk check`: verifying an environment's wiring.** `bin/check`
   (written by the base app) loads `config/load` and runs a read-only check
   for each loaded module. The checks belong to the framework modules
   (`Monk::Mail.check`, `Monk::Storage.check`, ...), not to the scaffold, so
   they work in a deployed app. Output and exit codes match `monk add`'s (text
   and `--json`). It covers what boot (missing settings) and `rake test`
   (wiring in the test environment) can't: problems that otherwise show up the
   first time a real user hits them.
   - **Before switching traffic to a deploy**, the main use:
     - SMTP connect and login without sending;
     - Postgres reachable with no migrations pending (including a module's
       new ones, such as recurring jobs');
     - Redis and `LISTEN` reachable (`LISTEN` doesn't work through
       PgBouncer in transaction mode);
     - values that are present but wrong: a placeholder `AUTH_SECRET`,
       `PUBLIC_URL` on `http://`, `LIVE_WS_URL` not on `wss://`,
       `WS_ALLOWED_ORIGINS` missing `PUBLIC_URL`, VAPID keys that don't
       match.
   - **A local "doctor"**: services up, env files filled in, versions
     matching `.ruby-version`/`Gemfile.lock`.
   - **Agents** get one diagnosis to act on (`--json`).
   - **Bug reports** get versions, modules and failed checks, with secrets
     redacted.
   - **After upgrading Monk**, a first signal that a module needs something
     the app lacks, such as a new migration.

   It isn't a load balancer's health check: it's heavier and runs once per
   deploy. A test email is opt-in (`--send-test-mail=addr`). It builds on the
   check command each `monk add` generator declares for its service
   (`docs/history/plan-scaffold.md` decision 29). Storage shipped first
   (0.23), so this release adds its check too: bucket access, and CORS
   allowing `PUBLIC_URL` (the checks `bin/storage_check` runs by hand
   today).

6. **0.27: Richer HTML support, forms first.** Views offer only `render`, `h`,
   `raw` and `asset_path`, with no form helpers (`docs/design/views.md`
   deliberately left them out). Templates write every form by hand, including
   its CSRF field and the values to fill back in after a failed submit. Before
   helpers, plain forms need two things Monk lacks: `params` from an
   `application/x-www-form-urlencoded` body (only the query string and JSON
   bodies are parsed today), and `require_csrf!` accepting a form field, not
   only the `X-CSRF-Token` header. Until then a page posts with `fetch`, as
   the auth module's login page does.

## To evaluate

Gaps that any real app built on Monk may run into but that need a design
before they become features.

- **Upgrading an app made by an older Monk.** `monk add` adds modules to an
  app but doesn't upgrade one written by an earlier version, so moving an app
  to 0.21's layout means bringing each part over by hand. Options range from
  upgrade notes per release in the `CHANGELOG` to a `monk upgrade` command.
  `monk check`'s "after upgrading Monk" signal covers part of it.

## Other work

Not features, but important.

- **Monk vs. Rails analysis.** A proper comparison with Rails: what Monk
  covers, what it leaves out, and when to choose one over the other.
  `docs/framework-comparison.md` is a starting point, but it measures
  footprint and complexity against Sinatra and Rails rather than going into
  depth.
- **A GitHub Pages site for the project**, set up after the Rails analysis.
