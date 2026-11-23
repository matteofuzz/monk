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
   (`docs/history/plan-live-networks-presence.md`). A few device checks on a
   deployed app are still open: see "Open checks" below.
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
   app installed on the Home Screen. Done (2026-11-18,
   `docs/history/plan-pwa-push.md`), checked on an iPhone, Android, and
   Chrome, Safari and Firefox on macOS.
   - **PWA scaffolding.** Done: `monk add pwa` (`docs/guides/pwa.md`): a
     web app manifest and a `sw.js` served at the root scope, checked at
     boot, with no `fetch` handler, so it never gets in the way of the
     Live client.
   - **Web push, `Monk::Push`.** Done: `monk add push`
     (`docs/guides/push.md`, ADR 0020): VAPID keys, subscriptions tied to
     auth sessions, sending from a job per device, and deleting
     subscriptions the push service reports as gone (404/410).

5. **0.26: Richer HTML support, forms first.** Done (2026-11-20,
   `docs/history/plan-forms.md`). Plain HTML forms work with no
   JavaScript, and the default answer to "should Monk do this?" stayed
   no: no form helpers and no validation API, only documented patterns
   (`docs/guides/forms.md`).
   - **Forms.** Done: urlencoded bodies and nested `params`, `_method`,
     `self.status` sent, `csrf_field`, flash messages, and redirects only
     to the app unless `allow_other_host: true`.
   - **Safe by default.** Done: other sites' browser requests are
     refused on every route (`allow_cross_origin: true` opts out), there
     are security headers on every response, and parsed bodies are
     capped at 1 MB.
   Also in this release, from a first real deployment:
   - **Presence on a closed iPhone app.** Done: a closed page reads away
     at once, so its push is sent. Measured on an iPhone.
   - **A CSRF cookie that no longer verifies.** Done: it's reissued for
     a valid session.
   - **Deploying websocket, jobs and auth together.** Done:
     `monk add deploy` writes the Compose stack, Caddy's `/ws` route and
     the env example from the app's modules, with secrets and push keys
     made on the host. `docs/guides/deploy-hetzner.md` is the tested
     deploy on Hetzner Cloud with Brevo, from the accounts to backups.

6. **0.27: Catching wrong settings early, and other enhancements.** A
   smaller release than the `monk check` command first planned. Most of
   what that command would check already fails loudly (Postgres, pending
   migrations, Redis), is set once per environment rather than per
   deploy, or can't be seen from inside the app (TLS, Caddy's `/ws`
   route: the curl checks in `docs/guides/deploy-hetzner.md` stay the
   way to test those). What's left:
   - **Values that are present but wrong, refused at boot in
     production.** Done (`docs/guides/settings.md`): a placeholder or
     short `AUTH_SECRET`, `PUBLIC_URL` that isn't an `https://` origin,
     `LIVE_WS_URL` not on `wss://`, an `allowed_origins` entry that isn't
     an origin. `PUBLIC_URL` is now always allowed, and
     `WS_ALLOWED_ORIGINS` lists only the other origins. This extends the
     checks `Monk::Settings` already makes for `MONK_ENV` and
     `LOG_LEVEL`: no new command, and it runs on every boot, before any
     traffic.
   - **Checking SMTP login without sending.** Login is by magic link,
     so broken SMTP means nobody can log in, and nothing shows it until
     someone tries. Done: `Monk::Mail.check` (`docs/guides/mail.md`),
     and a step in the deploy guide.
   - **A read-only check of the bucket's CORS rule** for `PUBLIC_URL`,
     run once when the bucket is set up (`bin/storage_check` applies and
     removes rules, so it needs a test bucket). Done:
     `Monk::Storage.check`, which also checks the lifecycle rule.
   - **A review of the code and the test suite.** Done
     (`docs/history/plan-code-review.md`). Two goals: fewer lines
     (duplication, code no longer needed, simpler ways to do the same
     thing) and best practice (Ruby idioms, error handling, Ractor
     safety). For the tests, the same two goals, plus a coverage check:
     measure it, and fill the gaps that matter, not chase a percentage.
   - **A review of all the docs for clarity.** README, guides, ADRs,
     SETUP.md and the scaffold's templates: easy to follow for someone
     new to Monk, consistent with each other and with the code as it is
     now, and without outdated references.
   - **Ruby 4.1 fixes, ahead of its release.** Done:
     `Monk::Base.freeze!` and the pool work on 4.1.0-preview1, and the
     pool no longer hangs when stopped while a worker is still
     connecting, a hang 4.0 has too.
   - Other enhancements found along the way.

   Left out until a real need shows up: a local "doctor" (the `bin/`
   scripts and Bundler already say what's wrong), `--json` output for
   agents, redacted bug-report output, and a `LISTEN` check through
   PgBouncer (Monk's deploy stack has none).

7. **Ruby 4.1 support, after its release** (expected 2026-12-25). The
   recheck in `docs/plan-ruby-4-1.md` §7: final NEWS, the suite on 4.0 and
   4.1, Linux/Docker, a load test for per-Ractor GC, then the templates
   and the upgrade guide.

## Open checks

Steps left from releases that shipped, run by hand on a real device or
on the benchmark's VM rather than in code. Their plans are in
`docs/history/`.

- **0.24: Live on real phones** (`docs/history/plan-live-networks-presence.md`,
  "A0 still open"). On a deployed app, behind TLS and its proxy, with
  the server log at hand:
  - iPhone with the current client: screen locked, and switched to
    another app, for 1 and 5 minutes, then back.
  - Airplane mode for 30 s, then back.
  - Screen locked for 15 minutes.
  - Why Android DuckDuckGo's socket closed cleanly after 441 s.
- **0.22.1: the WebSocket server's connect ceiling**
  (`docs/history/plan-ws-connect-ceiling.md`):
  - The VM run: the benchmark's S6 at a sweep of connect rates, 25K
    sockets held, on its 8-core VM.
  - The plan's item 10, on each Ruby 4.1 preview and on the release (with
    release 7 above): held 0 / 5K / 15K sockets, `--server-cpus` 0 / 0-1
    / 0-3, and a churn step, recording global GCs and RSS. If Ruby's
    #22454 and #22455 are fixed in 4.1, the WebSocket process recommends
    4.1 and the plan's items 6 and 9 are dropped; if not, item 6 for
    4.0, then 9 only if one process at 25K held is still too slow.
  - Broadcast latency at 25K sockets (the benchmark's S7 with more
    sockets): the same GC pauses likely slow it.
  - `docs/guides/persistence.md`'s "about 1,350 a second", restated for
    a burst into an empty server, not one already holding thousands.

## To evaluate

Gaps that any real app built on Monk may run into but that need a design
before they become features.

- **Upgrading an app made by an older Monk.** `monk add` adds modules to an
  app but doesn't upgrade one written by an earlier version, so moving an app
  to 0.21's layout means bringing each part over by hand. Options range from
  upgrade notes per release in the `CHANGELOG` to a `monk upgrade` command.
  `bin/migrate status` already shows a module's new migrations.

## Other work

Not features, but important.

- **Monk vs. Rails analysis.** A proper comparison with Rails: what Monk
  covers, what it leaves out, and when to choose one over the other.
  `docs/framework-comparison.md` is a starting point, but it measures
  footprint and complexity against Sinatra and Rails rather than going into
  depth.
- **A GitHub Pages site for the project**, set up after the Rails analysis.
