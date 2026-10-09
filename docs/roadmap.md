# Roadmap

Features to add, in the order they're planned to ship. Each step is one
release, with the version it's proposed for. Not a commitment: each one
gets its own design doc and plan when work on it starts.

## Releases

1. **0.21.1: Fixes to the 0.21 scaffold.** Both affect every app
   `monk new` writes today.
   - **The `:notify` pool.** `monk add websocket --transport=postgres`
     should scaffold the publisher pool 0.20.0 introduced
     (`Pg.pool(:notify, size: 1)`, `PgFanout.new(..., db_pool: :notify)`,
     started in `config.ru` and the test helper). Without it every
     `bin/server` worker opens its own publishing connection.
   - **The scaffolded `Dockerfile` doesn't build.** Its builder stage has no
     compiler, but `monk add postgres` adds `gem "irb"`, whose dependencies
     (`erb`, `io-console`, `prism`) compile native extensions. Either
     `build-essential` in the builder, or `irb` in the development group and
     `BUNDLE_WITHOUT` in the image.

2. **0.22: Recurring jobs and auth housekeeping.** Until then, an app that
   prunes old rows on a schedule needs a job that re-enqueues itself.
   - **Scheduled jobs.** Recurring jobs on a cron-like schedule in
     `Monk::Jobs`. One-off delayed jobs already exist (`enqueue(..., wait:)` /
     `at:`); recurring ones were left out of the first version
     (`docs/guides/jobs.md`, "What's not here"). The plan,
     `docs/plan-scheduled-jobs.md`, is on the `main_dev/scheduled_job` branch.
     It predates scaffolding by module: its scaffold phase still says
     `monk new --jobs` and must become a change to the jobs generator
     (`monk add jobs`, ADR 0017).
   - **Cleaning up `Monk::Auth`'s own tables.** `sessions` and `login_tokens`
     belong to `Monk::Auth`, and expired rows pile up in every app, roughly
     one session a month per active person. `Monk::Auth` ships the cleanup as
     a recurring job: the first real user of the feature above.
   - **An index on `sessions (subject)`.** Any app that looks up a person's
     sessions needs it, including a future "log out everywhere". Today each
     app has to add it in its own migration; it belongs in Monk's auth
     schema.
   - **A rate limit on login emails.** `docs/guides/auth.md` leaves "your
     per-email rate limit" to the app, but every app with magic links needs
     one. It takes one table and one upsert, small enough to move into
     `Monk::Auth`.
     `Monk::Auth::RateLimiter` stays as it is: per process, in memory,
     approximate.

3. **0.23: Live on real networks, and presence.** For apps that show
   whether a person is online, on mobile browsers as well as desktop ones.
   - **Mobile.** The Live client already reconnects with a jittered backoff
     (500 ms to 30 s), and the WebSocket server can ping (`ping_interval:`).
     Still missing, and belonging in the Live client and the WebSocket server
     rather than in each app's JS: a client-side timeout that notices a dead
     socket, for example after a phone changes network, instead of waiting
     for the OS to close it; and reconnecting and resyncing on
     `visibilitychange`, after a tab was backgrounded or suspended.
   - **Presence: is this person connected?** Only the WebSocket server knows
     who has a socket open, and presence is listed as missing in
     `docs/guides/live.md`. A valid session only means "logged in
     somewhere", not "online". Monk would track connected subjects, remove
     them on disconnect or timeout, and share them across processes through
     the fanout. An ADR comes first, to decide where the shared state lives
     (each process's memory, Postgres, Redis), how a process that dies
     without disconnecting its sockets gets cleaned up, and whether it's a
     Live feature or a WebSocket one.

4. **0.24: PWA and web push.** Together because on iOS web push needs the
   app installed on the Home Screen.
   - **PWA scaffolding.** A web app manifest and a `sw.js` served at the
     root scope, without getting in the way of the Live client.
   - **Web push, `Monk::Push`.** VAPID keys, storing subscriptions, sending
     from a job, and deleting subscriptions the push service reports as gone
     (404/410). Nothing in it is specific to one kind of app, and it makes a
     PWA useful to any Monk app.

5. **0.25: `monk check`: verifying an environment's wiring.** `bin/check`
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
   (`docs/history/plan-scaffold.md` decision 29). Storage ships after it, so
   storage's release adds its own check (bucket access, CORS for
   `PUBLIC_URL`).

6. **0.26: File storage, `Monk::Storage`.** An opt-in storage layer
   configured by one `STORAGE_URL`. It has one S3-compatible backend
   (Hetzner, R2, B2, AWS, MinIO) that signs its own SigV4 requests, and
   local files in development and test. Browsers upload straight to the
   bucket through a presigned PUT, and downloads go through an app route
   that redirects to a signed link. Designed in ADR 0016; the ADR and
   `docs/plan-storage.md` are on the `main_dev/monk_storage` branch. The
   plan's scaffold phase still says `monk new --storage` and must become a
   generator of its own (`monk add storage`, ADR 0017). Before the S3
   backend ships, four open items need checking on a real Hetzner bucket:
   the signed `Content-Length`, CORS for `PUT`, the `tmp/` lifecycle rule,
   and same-bucket copy. The plan's earlier phases don't depend on them.

7. **0.27: Richer HTML support, forms first.** Views offer only `render`, `h`,
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
