# Scaffolded app layout (`app/`, directories by role) — implementation plan

> **Historical document.** It records how this was planned or built at the time and may describe things that have since changed or shipped. For how Monk works today, see [`docs/guides/`](../guides/).

Status: planned 2026-09-29, nothing implemented yet.
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
  models/.keep                              # NEW, --postgres
  mailers/app_mailer.rb                     # NEW, --auth: moved out of config/auth.rb
  jobs/hello_job.rb send_login_link.rb      # was jobs/
  views/index.erb layouts/app.erb mail/magic_link.erb live/_hits.erb   # was views/
db/migrate/  public/  bin/  test/
```

`presenters/` and `broadcasts/` aren't written: the scaffold has no code
for them (ADR 0015). `load.rb` loads them if they exist, and the guide
explains them.

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
# read models, mailers and broadcasts render what models return, and jobs
# call all of them. Everything is loaded before Monk.boot freezes the app,
# since nothing can be loaded later from a worker Ractor.
%w[models presenters mailers broadcasts jobs].each do |role|
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
2. **Module configs stop loading app code.** `config/jobs.rb` loses its
   `jobs/*.rb` glob. `config/persistence.rb` doesn't gain one.
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
6. **`app/models/` ships as `.keep`**, since there's no demo model, and
   only with `--postgres`.
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

### Phase 2: `--postgres` and `--auth`

- `POSTGRES_FILES` adds `app/models/.keep`.
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

### Phase 6: docs

- `docs/guides/scaffolding.md`: the new tree, and a "Where code goes"
  section with ADR 0015's role table, the rule for code that fits no role
  (a new role name, never `services/`/`utils/`; `lib/` if it isn't
  specific to the app), and the load order and `require_relative`
  rule for class-body references.
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

## Open questions

None. The name `config/boot.rb` was dropped for `config/load.rb`, since
Boot already means the freeze step `Monk.boot` triggers (ADR 0015).
