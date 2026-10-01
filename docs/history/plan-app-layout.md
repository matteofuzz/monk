# Scaffolded app layout (`app/`, directories by role) — implementation plan

> **Historical document.** It records how this was planned or built at the time and may describe things that have since changed or shipped. For how Monk works today, see [`docs/guides/`](../guides/).

Status: complete 2026-09-29: Phases 1–7 and the `#listen!` change. Phase 1 took every `views/` →
`app/views/` path move and the `--live` `app/app.rb` override from Phases
2–4, since a single `config.ru` for every flag needs them at once. Those
phases keep their other work.
Companion record: [`../adr/0015-scaffolded-app-layout-app-dir-by-role.md`](../adr/0015-scaffolded-app-layout-app-dir-by-role.md)
(why `app/`, why role names rather than Monk module names, the list of
roles, and why `app/` is loaded eagerly in a fixed order).

Only `monk new`, its templates and the docs change. `lib/monk` outside
`scaffold.rb` and `templates/` is untouched: `views`/`assets` already
take any directory. Same approach as the other plans: small red → green
slices, updating the scaffold tests first.

## Target layout (every flag on)

```
config.ru                                   # the same three lines for every flag
config/
  load.rb                                   # NEW
  settings.rb persistence.rb auth.rb mail.rb jobs.rb live.rb
app/
  app.rb                                    # NEW: class App, moved out of config.ru
  models/ presenters/ helpers/ mailers/ broadcasts/ jobs/   # NEW, always, each with a .keep
  mailers/app_mailer.rb                     # NEW, --auth: moved out of config/auth.rb
  jobs/hello_job.rb send_login_link.rb      # was jobs/
  views/index.erb layouts/app.erb mail/magic_link.erb live/_hits.erb   # was views/
db/migrate/  public/  bin/  test/
```

Every role directory is written, whatever the flags, with a `.keep`
(ADR 0015). Flags add files next to the `.keep`s. `load.rb` skips any
directory an app deletes.

`config.ru`:

```ruby
require_relative "config/load"   # load the configs and app/
require_relative "app/app"

run Monk.boot(App)               # Boot: freeze and serve
```

`config/load.rb`, every flag on (the scaffold writes only the enabled
config lines):

```ruby
require_relative "settings"
require_relative "auth"          # or "persistence" without --auth; auth.rb requires it
require_relative "mail"
require_relative "jobs"
require_relative "live"

# The app's code, by role, in the order they call each other: presenters
# read models, helpers, mailers and broadcasts use both, and jobs call all
# of them. Everything is loaded before Monk.boot freezes the app, since
# nothing can be loaded later from a worker Ractor. Order only matters for
# code that runs while a file loads; methods may use any role.
%w[models presenters helpers mailers broadcasts jobs].each do |role|
  Dir[File.expand_path("../app/#{role}/**/*.rb", __dir__)].sort.each { |file| require file }
end
```

## Decisions

1. **`config/load.rb` holds the config requires `config.ru` has today,
   then loads `app/`.** `wire_config_ru!` becomes `wire_load!`: the same
   anchor (`require_relative "settings"`) and the same order (persistence
   or auth, mail, jobs), plus `live` for `--live` (today `live/config.ru`
   requires it itself). The loop over roles is in the template after the
   anchor and is the same for every flag.
2. **Module configs stop loading app code by folder** (ADR 0015).
   `config/jobs.rb` loses its `jobs/*.rb` glob. `config/persistence.rb`
   doesn't gain one. A config that needs specific app files requires
   them itself (`config/auth.rb` → `app/mailers/app_mailer`).
3. **`app/app.rb` is not required by `load.rb`.** `config.ru` and
   `test/test_helper.rb` require it. `bin/jobs` then doesn't define routes
   or start the `--live` demo's `StateRactor`.
4. **`bin/jobs` and `bin/console` require `config/load`**, replacing their
   own config lists. `bin/jobs` still sets `Monk::Views.root`, now
   `File.expand_path("../app/views", __dir__)`. `bin/console` then needs
   whatever env vars the enabled configs need, the same as `bin/server`.
   `bin/websocket_server`, `bin/migrate` and `bin/setup_db` keep their
   short lists: they need no app code, and the WebSocket server must boot
   without `MAIL_URL`.
5. **The magic-link sender moves to `app/mailers/app_mailer.rb`**, and
   `DELIVER` is renamed `MAGIC_LINK`, since the module will hold more than
   one email (monk_talk's `Mailer::MAGIC_LINK`). `config/auth.rb` does
   `require_relative "../app/mailers/app_mailer"` and passes
   `deliver: AppMailer::MAGIC_LINK`. `load.rb`'s glob requires the same
   file again by its absolute path, which Ruby skips. Phase 2 checks that
   with a test rather than assuming it.
6. **Every role directory ships with a `.keep`, whatever the flags**
   (ADR 0015). `Scaffold::APP_ROLES` lists them in `load.rb`'s order, and
   a test keeps the two lists in step. The `.keep` stays when a flag adds a
   real file to the directory. The template `.keep`s must be tracked in
   git, since the gemspec's file list is `git ls-files`.
7. **`views "app/views"`** in `app/app.rb`, relative to the working
   directory like `assets "public"` (ADR 0015, Considered Options).
8. **Existing apps aren't migrated.** A CHANGELOG entry lists the moves by
   hand: `git mv views app/views`, `git mv jobs app/jobs`, move `class App`
   into `app/app.rb`, add `config/load.rb`, point `bin/jobs` at it, and
   (optional) move `AppMailer` out of `config/auth.rb`.

## Phases

### Phase 1: base skeleton

- `templates/base/config.ru` → the three lines above.
- New `templates/base/app/app.rb`: `class App` with today's routes,
  `views "app/views"`.
- New `templates/base/config/load.rb`: `require_relative "settings"` and
  the role loop.
- `git mv templates/base/views templates/base/app/views`.
- `BASE_FILES`: the new keys and paths.
- `wire_config_ru!` → `wire_load!` (decision 1).
- Tests (`scaffold_test.rb`): the skeleton-matches-templates test, the
  config.ru wiring tests (now asserting on `config/load.rb`, and that
  `config.ru` is the same for every flag), and the boot test. The boot
  test should `Dir.chdir(dest)` and require the real generated
  `config/load` + `app/app` instead of rebuilding `App` by hand, so it
  checks the file users actually get.
- A test that `load.rb` loads a file dropped into `app/presenters/` and
  `app/broadcasts/`, and that a missing role directory is fine.
- Added after Phase 1 with the `helpers/` role: that test also covers
  `app/helpers/`, and a test that a helper module in `app/helpers/`
  (`Monk::Context.include`) is callable from a template in the booted
  generated app.
- Added after Phase 1: every role directory with its `.keep`
  (decision 6), and a test that they all exist.

### Phase 2: `--postgres` and `--auth`

- `bin/console` requires `config/load` (decision 4).
- New `templates/auth/app/mailers/app_mailer.rb`, with the module moved
  out of `templates/auth/config/auth.rb` and renamed (decision 5).
  `AUTH_FILES` adds it and moves `magic_link.erb` to
  `app/views/mail/magic_link.erb`. The render name (`"mail/magic_link"`)
  is relative to the views root and doesn't change.
- Tests: the postgres/auth file lists and the wiring assertions. A test
  that the generated `config/auth.rb` followed by `config/load.rb` loads
  `app_mailer.rb` once (no "already initialized constant" warning). A
  test that `config/auth.rb` loads without `config/mail.rb`, as
  `bin/websocket_server` does.

### Phase 3: `--jobs`

- `JOBS_FILES` / `JOBS_AUTH_FILES`: `app/jobs/...`; move the templates to
  `templates/jobs/app/jobs/`.
- `config/jobs.rb`: drop the glob (decision 2) and fix the comment.
- `bin/jobs`: require `config/load`; the new `Views.root` (decision 4).
- `add_jobs_route!`: edits `app/app.rb` instead of `config.ru`. The anchor
  (the `/api/hello` route line) is unchanged.
- Tests: `scaffold_jobs_test.rb`, including the drain and real `bin/jobs`
  process tests, which confirm the new paths load and that
  `SendLoginLink` reaches `AppMailer::MAGIC_LINK`.
- Done as planned, plus: the jobs test helpers load the generated
  `config/load.rb` instead of each config by hand. With `--live`,
  `bin/jobs` now loads `config/live.rb` too, which starts the fanout's
  subscriber Ractor and connection, so a new test runs `bin/jobs` from a
  `--jobs --live --postgres` app and checks it runs a job and exits 0 on
  TERM (ADR 0015 notes the connection).

### Between Phases 3 and 4: only the WebSocket process listens

Done 2026-09-29. With Phase 3, `bin/jobs` (and `bin/console`) loaded
`config/live.rb`, whose fanout started a subscriber connection when built,
so every process listened. We chose an explicit `#listen!` on
`RedisFanout`/`PgFanout` (a no-op on `Registry`), called once by
`bin/websocket_server` through `Monk::Live.listen!`. `#register` raises
before it. The alternatives weighed were keeping it as it was, keeping
Live out of `bin/jobs`, and a lazy start on the first `#register`
(`docs/design/websocket.md`, "Who listens"). The `--live` `bin/jobs` test
now also checks that `bin/jobs` doesn't `LISTEN`. monk_talk's
`bin/websocket_server` needs `Monk::Live.listen!` added (CHANGELOG).

### Phase 4: `--live`

- `LIVE_OVERRIDES` swaps `app/app.rb` (from a new
  `templates/live/app/app.rb`) and `app/views/index.erb`, not `config.ru`.
  `templates/live/config.ru` is deleted: every app now has the same
  `config.ru`.
- `LIVE_FILES`: `app/views/live/_hits.erb`. `add_live_to_layout!`:
  `app/views/layouts/app.erb`. The client stays in `public/js/monk_live`.
- `config/live.rb` is required from `load.rb` (decision 1).
- The demo's `Monk::Live.patch` stays inline in the `/hit` route. It's one
  line, and a `broadcasts/` file for it would be more to read than the
  route itself. The guide shows when to move one out.
- Tests: `scaffold_live_test.rb`, including the `ruby -c` test over every
  generated file.
- Done 2026-09-29. Everything above except the last bullet had already
  landed in Phase 1. What Phase 4 added: a test that boots the generated
  `--live` app the way `config.ru` does (`config/load` + `app/app.rb` +
  `Monk.boot`), renders the counter, and posts `/hit`, which publishes
  through `Monk::Live.patch` over Redis. No test had run the generated
  live app as a whole before; breaking the partial name makes it fail.

### Phase 5: generated SETUP.md

- `base_setup_md_content`: drop the "Extract `App` into its own file"
  advice, which is now done. The test helper requires `config/load` and
  `app/app`.
- `postgres_setup_md_content`: the test helper's config list becomes
  `require_relative "../config/load"`, so it no longer duplicates the
  list per flag.
- Every `views/...`, `jobs/...`, `config.ru` and `AppMailer::DELIVER`
  mention in the setup notes (`live_setup_md_content_*`,
  `mail_setup_note`, `jobs_setup_note`, `auth_mail_sentence`, the
  `JOBS_ROUTE` comment, the `AUTH_FILES` comment). `monk new`'s printed
  summary lists no paths, so it's unchanged.

- Done 2026-09-29. Beyond the above: every variant's test helper ends
  the same way (`config/load`, `app/app`, `APP = Monk.boot(App)`), and a
  `test/app_test.rb` sample makes a request (`GET /hello`) through it,
  replacing the old `test/settings_test.rb`. `--live --redis` now puts
  `REDIS_URL` in `.env.test`, since the test helper loads
  `config/live.rb`. Building the fanout connects to nothing, so the tests
  pass with Redis unreachable. Checked by generating four apps (base,
  `--mail`, `--live --redis`, `--auth --jobs --live`), following their
  SETUP.md test section verbatim against this checkout, and running
  `bundle exec rake test` in each: all green.

### Phase 6: docs

- `docs/guides/scaffolding.md`: the new tree, and a "Where code goes"
  section with ADR 0015's role table, the rule for code that fits no role
  (a new role name, never `services/`/`utils/`; `lib/` if it isn't
  specific to the app), `helpers/` as `Monk::Context` mixins only (and
  how a helper differs from a presenter), the load order (methods may
  use any role; only load-time references need `require_relative`), and
  configs requiring the specific app files they need (the `config/auth.rb`
  and monk_talk `config/live.rb` examples).
- `docs/guides/mail.md` and `auth.md`: `app/mailers/app_mailer.rb`,
  `AppMailer::MAGIC_LINK`, and the `require_relative` from
  `config/auth.rb`.
- `docs/guides/live.md`: a short example of moving a multi-patch
  `Monk::Live.batch` out of a route into `app/broadcasts/`.
- The path mentions in `views.md`, `jobs.md`, `deploying.md`,
  `settings.md`, `persistence.md`, `boot-and-shared-state.md`, and
  `README.md`.
- `CONTEXT.md`: no new terms; the role names are ordinary words.
- `CHANGELOG.md`: the layout change and the manual upgrade steps
  (decision 8). The version bump is left to the release.

- Done 2026-09-29. Beyond the above: `docs/guides/scaffolding.md` got
  the full tree, "Where code goes" (the role table, presenter vs helper,
  no catch-alls, templates only in `app/views/`, directories whose module
  is off), "Load order", and a SETUP.md section; its retrofit steps now
  edit `config/load.rb`. `settings.md`, `persistence.md` and
  `deploying.md` (which also says `bin/jobs` needs `REDIS_URL` with
  `--live --redis`, and that only the WebSocket process listens) were
  updated too. `live.md` had no stale path beyond one template comment,
  and needed no broadcasts example: moving code into `app/broadcasts/` is
  covered by the scaffolding guide's table.

### Phase 7: verify

- `bundle exec rake test`, with Postgres and Redis available so the
  generated-app tests don't skip.
- Generate `--auth --jobs --live --redis` and `--live --postgres` into a
  temp directory, run `bin/setup_db`, `bin/server`, `bin/jobs`,
  `bin/websocket_server` and `bin/console`, and click through the index,
  `/hit` and `POST /jobs/hello`.
- Sort monk_talk's `lib/monk_talk/` by the role table on paper (not in
  its repo) and check that every file has an obvious home. It does as of
  this plan: see ADR 0015's table.

- Done 2026-09-29, all green. The suite: 781 runs, 0 failures, 0 skips,
  with Postgres and Redis. Two generated apps, pointed at this checkout,
  run for real (`bin/setup_db`, then `bin/server`, `bin/websocket_server`,
  `bin/jobs`):
  - `--auth --jobs --live --redis`: `/` renders the counter from
    `app/views`; a WebSocket client subscribed to `hits` receives the
    `<strong id="hits">1</strong>` patch after `POST /hit`; exactly one
    Redis subscriber exists with all three processes up (0 → 1), and
    publishing doesn't add one; `POST /jobs/hello` runs `HelloJob` from
    `app/jobs/`. `bin/console` sees `HelloJob`, `SendLoginLink`,
    `AppMailer::MAGIC_LINK` and the Live registry; a `SendLoginLink` it
    enqueued was sent by `bin/jobs` through `AppMailer::MAGIC_LINK`.
  - `--live --postgres`: the same Live checks over `LISTEN`/`NOTIFY`,
    with one `LISTEN` session (0 → 1), from `bin/websocket_server` only.
- Seen along the way, not changed here (both as in 0.18):
  - With `--auth`, `bin/websocket_server` authenticates every connection,
    so the `--live` demo's socket needs a session (a Bearer token or the
    session cookie) even though its `hits` rule allows anonymous
    subscribers. The check above used a session from
    `Monk::Auth.request_login` + `redeem`.
  - `bin/websocket_server` has no `TERM` handler, so it ends by the
    signal rather than exiting 0 as `bin/server` and `bin/jobs` do.
  - Both fixed right after this plan, as their own changes: `769b1b2`
    (`authenticate: :optional`, so the `--auth --live` demo works for
    visitors; `docs/design/websocket.md`, "Anonymous connections") and
    `7d49a7f` (`TERM` exits 0, and `monk_live.js` jitters reconnects;
    "Stopping the server").

## Open questions

None. The name `config/boot.rb` was dropped for `config/load.rb`, since
Boot already means the freeze step `Monk.boot` triggers (ADR 0015).
