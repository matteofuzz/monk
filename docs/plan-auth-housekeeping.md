# Auth housekeeping: cleanup job, `sessions (subject)` index, login-email rate limit — implementation plan

Branch: `main_dev/dev_0_22_0` (the release branch). Drafted 2026-10-13.
All phases done (2026-10-13). Decisions confirmed 2026-10-13 (the sweep at 03:17 UTC, a 60-second
interval, a test-only `clear_login_requests!`, the key `monk_auth_sweep`).
The three auth items of the 0.22 roadmap entry, plus the auth section of
the 0.22 upgrade guide. They share one migration, one change to the
auth scaffold and one upgrade-guide section, so they're one plan.
Builds on recurring jobs ([`history/plan-scheduled-jobs.md`](history/plan-scheduled-jobs.md),
ADR 0016) and on the auth design ([`design/auth-sessions.md`](design/auth-sessions.md)).

Same approach as the other plans: small red → green slices, one failing
test per seam, against a real test Postgres.

## The problem

Every app with `monk add auth` needs three things Monk leaves to it today:

- **Expired rows pile up.** `sessions` and `login_tokens` grow by roughly
  one session a month per active person. `Monk::Auth.sweep!` deletes
  expired rows, but nothing calls it: the design doc says "a `bin/` task
  ... run on a schedule", and until 0.22 there was no schedule.
- **Finding a person's sessions scans the table.** `Monk::Auth.revoke_all`
  (`Session.where(subject:)`), any "who is online" query and a future
  "log out everywhere" all look sessions up by `subject`, which has no
  index.
- **Login emails have no durable rate limit.** Without one, anyone can
  make the app send mail to any address. The scaffolded routes use
  `Monk::Auth::RateLimiter`, which counts per process and forgets on
  restart: with several `bin/server` processes the limit multiplies. The
  routes' own comment says "count in the database instead", and
  `docs/guides/auth.md` leaves "your per-email rate limit" to the app.

## Constraints from what exists

- **The link is made in the job, not the request.** With jobs,
  `Monk::Auth::SendLoginLink` creates the token when it runs
  (ADR 0014). So `login_tokens` can't tell that a request is already
  queued, and the limit must be checked in the route, before
  `enqueue`. It can't live in `request_login`.
- **`Monk::Auth::SendLoginLink` is defined once both `monk/auth` and
  `monk/jobs` are loaded** (the last line of each file). A job class
  shipped by auth can use the same mechanism.
- **Generators only create files and copy migrations** (ADR 0017): there
  is no "append a line to an existing file". Wiring that depends on
  which modules are installed has to be decided at load time.
- **`config/load.rb` loads `config/recurring.rb` last**, after every
  module config and `app/`.
- **Auth's tables have no `monk_` prefix** (`sessions`, `login_tokens`),
  unlike the jobs tables.
- **No compatibility layer for existing apps** (they're internal): new
  apps get the clean template; existing ones follow the upgrade guide.
  An existing app may already have its own index on `sessions (subject)`
  or its own login-request table.

## Decisions

1. **Scheduling the sweep: a line in the jobs template's
   `config/recurring.rb`, guarded by `defined?`.**

   ```ruby
   # With auth (monk add auth): deletes expired sessions and login tokens nightly.
   Monk::Jobs.recurring "monk_auth_sweep", Monk::Auth::Sweep, cron: "17 3 * * *" if defined?(Monk::Auth::Sweep)
   ```

   | Option | Verdict |
   |---|---|
   | **A. The guarded line in `config/recurring.rb`**, written by `monk add jobs` | **Chosen.** Works whichever module is added first, since the file loads last. Visible and editable in the app. No generator code. |
   | B. `Monk::Auth` declares the task itself when jobs is loaded | Rejected. Every app gets a schedule it never wrote and can't change or turn off without patching Monk. |
   | C. The auth generator appends the line to `config/recurring.rb` | Not possible: generators don't append to files. And with auth added first, the file doesn't exist yet. |
   | D. The app schedules it itself, from the guide | Rejected as the default: every app needs it, so every app would copy the same line. Still what an app without jobs does (below). |

   Active, not commented: cleanup is hygiene every app with auth needs,
   and one nightly job is no noise. 03:17 UTC, off the hour, away from
   other tasks scheduled at `0 3`. **An app with auth and no jobs** has no
   scheduler: the guide says to call `Monk::Auth.sweep!` from its own
   cron, or add jobs.

2. **`Monk::Auth::Sweep`, a `Monk::Job` defined like `SendLoginLink`**
   (`lib/monk/auth/sweep.rb`, required at the end of whichever of
   `monk/auth` and `monk/jobs` loads second). `perform` calls `sweep!`
   and logs the counts. Default queue, default attempts.

3. **`sweep!` deletes in batches, and covers the new table.** Each table
   is deleted 10,000 rows per statement until a statement deletes fewer,
   so no lock is held long on a big backlog (the first sweep of an app
   that has never swept). It returns the counts, now with
   `login_requests:` (rows older than the interval, decision 5). Rows go
   when they expire, as today: no retention period. An app that wants to
   keep expired sessions for a while (to show "last seen", say) doesn't
   schedule `Sweep` and prunes its own way.
   No index on `expires_at`: `sessions` holds about `session_ttl` worth of
   sessions, so one scan a night is cheap. Revisit if a sweep shows up as
   slow.

4. **The index: `sessions_subject ON sessions (subject)`, in a new auth
   migration.** See decision 6 for which migration.

5. **The rate limit: one row per address, at most one login email per
   `login_request_interval` seconds.**

   ```sql
   CREATE TABLE login_requests (
     email TEXT PRIMARY KEY,
     requested_at TIMESTAMPTZ NOT NULL DEFAULT now()
   );
   ```

   ```sql
   INSERT INTO login_requests (email) VALUES ($1)
   ON CONFLICT (email) DO UPDATE SET requested_at = now()
     WHERE login_requests.requested_at < now() - make_interval(secs => $2)
   RETURNING 1
   ```

   - **API:** `Monk::Auth.allow_login_request?(email)`: true, and
     recorded, if no link was requested for this address within the
     interval; false otherwise. One statement, so two requests racing
     for the same address can't both pass. The name says "allow?" like
     `RateLimiter#exceeded?` says "exceeded?": both record the call.
   - **Configured** with `Monk::Auth.configure(login_request_interval: 60)`,
     the default. 60 seconds: long enough to stop a flood, short enough
     that a person who didn't get the email can ask again soon.
   - **The address is normalized for the limit only** (stripped and
     downcased), so `Ann@x.test` and `ann@x.test` share a limit. What the
     route passes to `request_login`/`SendLoginLink` is unchanged.
   - **One per interval, not N per window.** One row and one upsert;
     counting N per window needs a counter column and a reset rule for a
     limit no one has asked for. The scaffold's "5 per 10 minutes" becomes
     "1 per minute".
   - **Not covered:** one client asking for links to many addresses. A
     limit per IP or per account stays the app's (`RateLimiter` still
     works for that), and the guide says so.
   - **The table name** is `login_requests`, unprefixed like auth's other
     tables. An app that has its own table by that name renames one of
     them before upgrading; the upgrade guide says so.

6. **One new auth migration for both: `create_login_requests`** (the
   table and the index), `lib/monk/templates/auth/db/migrate/00000000000004_create_login_requests.{up,down}.sql`.
   `monk add auth` copies it after `create_auth_tables`; an existing app
   copies the same file (`monk help auth --file
   db/migrate/x_create_login_requests.up.sql`). One path for new and old
   apps, the way recurring jobs did it. The index is in it rather than in
   `create_auth_tables` so existing apps get it from the same file. An
   app that already indexes `sessions (subject)` under another name
   deletes that line before applying it (or drops its own index after);
   the guide says so. The prefix only orders the templates.

7. **The scaffolded login routes use the database limit.** The
   `auth-routes` example calls `halt(429) unless
   Monk::Auth.allow_login_request?(email)` and drops
   `AuthRoutes::LIMIT`. The warning "keep a rate limit" stays: the line
   is still what stops the route from mailing anyone. The `todo:` texts
   and the closing line keep "keep the rate limit".

8. **Testing: a test-only `Monk::Auth.clear_login_requests!`.** An
   app's tests that request two links for one address within the
   interval would get a 429. `clear_login_requests!` empties
   `login_requests`, and like `Monk::Jobs.clear!` it refuses to run
   unless `MONK_ENV=test`, raising a new `Monk::ClearLoginRequestsOutsideTestsError`
   (auth's errors live directly under `Monk`, in `lib/monk/auth/errors.rb`). The scaffolded `test/auth_test.rb` calls it
   in `teardown`. Chosen over a short interval in tests, which would test
   a different limit than production's, and over a new address per test,
   which every app would have to remember. `Monk::Jobs.clear!` doesn't
   touch auth's tables.

## Phases

1. **Schema.** The migration (decision 6) and `test/auth_schema_test.rb`
   (or the existing auth schema tests): the table, its primary key, the
   index, rollback. Add `login_requests` to the auth test helper's table
   setup and teardown.
   **Done (2026-10-13).** `lib/monk/templates/auth/db/migrate/00000000000004_create_login_requests.{up,down}.sql`;
   `test/auth_schema_test.rb` (5) applies auth's template migrations
   the way `test/jobs_schema_test.rb` does, since `AuthTestHelpers`
   writes its schema by hand. The helper now creates `login_requests`
   and the index too.
   Also fixed while running the suite: tests that froze Settings under a
   development or production `MONK_ENV` and never reset it (12, in the
   assets, logging and Ractor integration tests) left `Monk.env` reading
   that value for the next test, which broke `run_scheduler!`'s
   `MONK_ENV=test` check in some orders (4 seeds in 8). `test_helper.rb`
   now resets `Monk::Settings` before every test (`FreshSettings`).
2. **The rate limit.** `login_request_interval:` in `configure` (a
   positive Integer, default 60, checked at configure);
   `allow_login_request?`: first request allowed; a second within the
   interval refused; allowed again once `requested_at` is older than the
   interval (moved back in the test, no sleeping); different addresses
   independent; case and spaces normalized; two threads on two
   connections for one address: exactly one allowed.
   `clear_login_requests!` empties the table, and refuses outside
   `MONK_ENV=test`.
   **Done (2026-10-13).** In `lib/monk/auth.rb`: `LOGIN_REQUEST_SQL`,
   `allow_login_request?` (also raises `ArgumentError` for a blank or
   non-String address) and `clear_login_requests!`; the new error in
   `lib/monk/auth/errors.rb`. `login_request_interval:` must be a
   positive Integer, else `InvalidAuthConfigError`. Tests:
   `test/auth_login_requests_test.rb` (15), including that a refused
   request leaves `requested_at` alone. The race runs as 8 Ractors, each
   on its own connection, since threads in one Ractor would share one.
3. **Sweeping.** `sweep!` batched (a test with a batch size lowered
   through a test-only argument, deleting more rows than one batch), and
   deleting `login_requests` older than the interval while keeping recent
   ones. `Monk::Auth::Sweep` defined in either require order (like
   `SendLoginLink`'s test), `perform` sweeps and logs.
   **Done (2026-10-13).** `sweep!(batch_size: 10_000)` deletes each
   table in batches (`SWEEP_*_SQL` in `lib/monk/auth.rb`) and returns
   `login_requests:` too. Tokens and sessions still expire by the app's
   clock, as `redeem`/`verify` check them; login requests by the
   database's, as `allow_login_request?` does. `batch_size:` is a public
   keyword, checked to be a positive Integer, not test-only.
   `lib/monk/auth/sweep.rb` logs "Monk::Auth::Sweep: deleted N sessions,
   N login tokens, N login requests". Tests: `test/auth_sweep_test.rb`
   (5, the job run through `drain!` in a Ractor);
   `test/module_pairs_load_order_test.rb` checks `Sweep` next to
   `SendLoginLink` in both require orders; `AuthTest`'s sweep test
   expects the new count.
4. **Scaffolding.**
   - `lib/monk/generators/auth.rb`: `migration "create_login_requests"`
     after `create_auth_tables`.
   - `lib/monk/templates/auth/app/routes/auth.rb`: decision 7.
   - `lib/monk/templates/jobs/config/recurring.rb`: decision 1's line.
   - `auth/setup.md`, `auth/agents.md`: the limit (one per minute per
     address, configured in `config/auth.rb`) and the nightly sweep (with
     jobs; without, call `sweep!`). `jobs/agents.md`: the sweep line in
     `config/recurring.rb`.
   - `config/auth.rb` template: `login_request_interval: 60` with a
     comment, next to the other settings.
   - `lib/monk/templates/auth/test/auth_test.rb`: `teardown` calls
     `Monk::Auth.clear_login_requests!`.
   - Tests: `test/generators/auth_test.rb` (both migrations, in order);
     `test/generators/examples_test.rb` (the `auth-routes` probe's rate
     limit check now passes through the database: a second request is
     429, across the whole app); an app with auth and jobs lists
     `monk_auth_sweep` in `Monk::Jobs.recurring_tasks`, and one with jobs
     only doesn't (`test/generators/jobs_test.rb`); `test/exe_monk_test.rb`
     where `monk add auth`'s output lists the new migration.
   **Done (2026-10-13).** As listed, plus `docs/guides/scaffolding.md`'s
   auth entry. `monk add auth`'s output isn't pinned in
   `test/exe_monk_test.rb`, so nothing changed there. The jobs-recurring
   probe in `test/generators/examples_test.rb` now checks the demo task
   among others, since that suite's app has auth too and so declares
   `monk_auth_sweep`. The new generator tests load the app as development,
   which needs no `MAIL_URL`. The `auth-routes` probe checks a second
   request is 429, also in upper case, while another address isn't.
5. **Docs.**
   - `docs/guides/auth.md`: the rate limit (replacing "your per-email
     rate limit"), and cleanup (`sweep!`, `Monk::Auth::Sweep`, the line in
     `config/recurring.rb`, apps without jobs). `RateLimiter` described as
     the per-process tool for other limits.
   - `docs/design/auth-sessions.md`: a dated note where it says
     `StateRactor` rate-limits `POST /auth/request` and where it proposes
     a `bin/` sweep task, pointing here.
   - `CONTEXT.md`: a "Login request" term if the word needs pinning
     (a row in `login_requests`, not a login token).
   - **The auth part of the 0.22 upgrade guide** (`docs/guides/upgrading.md`):
     1. copy `create_login_requests` under a new timestamp, minus the
        index line if the app already has one; rename a clashing
        `login_requests` table first; `bin/migrate` on each database;
     2. replace the app's own per-email limit in its login route with
        `Monk::Auth.allow_login_request?(email)` (and drop its table, if
        it had one, once the new one is in use);
     3. with jobs: add the `monk_auth_sweep` line to `config/recurring.rb`
        (`monk help jobs --file config/recurring.rb`); without jobs:
        schedule `sweep!` some other way;
     4. optionally `login_request_interval:` in `config/auth.rb`;
     5. in the app's tests that log in, `Monk::Auth.clear_login_requests!`
        in `teardown`.
   - CHANGELOG ("Unreleased"), README's auth row.
   **Done (2026-10-13).** `docs/guides/auth.md`: "Rate-limiting login
   emails" and "Cleaning up expired rows", the three tables, and the job
   example's real `allow_login_request?` call. `docs/design/auth-sessions.md`:
   two dated "Update (Monk 0.22)" notes. `docs/guides/upgrading.md`:
   "Auth housekeeping (apps with auth)", five steps; the `monk help auth`
   commands it uses were run. CHANGELOG ("Unreleased", three entries;
   the test-order fix left out, since it's internal to Monk's suite);
   README's auth row; the scaffolding guide's quoted example.
   No `CONTEXT.md` term: it has no auth terms at all (no login token or
   session), so "Login request" alone would stand out more than help.

No ADR planned: each decision is small and recorded here. Open to one if
decision 1 (who schedules Monk's own jobs) becomes a pattern.

## Explicitly out of scope

- Rate limits per IP, per account or across addresses.
- N-per-window limits.
- A retention period for expired sessions.
- "Log out everywhere" itself (the index makes it cheap later).
- An index on `expires_at`.

## Open questions

None left (2026-10-13).
