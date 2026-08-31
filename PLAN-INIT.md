# Monk project scaffolding (`monk new`) — implementation plan

Branch: not yet created. Depends on: `Monk::Persistence::Pg` and
`Monk::Persistence::Pg::Migrator` (`main`, both done) — the `--postgres`
variant's templates are exactly the hand-written files
`PLAN-MIGRATIONS.md` Phase 5 added to `monk-consumer-test`. No companion
design doc yet, same call as `PLAN-MIGRATIONS.md`: the surface is small
enough to lock decisions in directly here.

Like the other plans, this develops in small, gradual, red → green cycles.
Each numbered step is one vertical slice: one failing test against its
seam, then the minimum code to pass it.

## Decisions locked in before Phase 1

1. **`monk` gets its first executable.** `monk.gemspec` currently ships
   zero (`spec.files` is `lib LICENSE.txt README.md` only) — this adds
   `spec.bindir = "exe"` / `spec.executables = ["monk"]`, a real scope
   expansion from "library you `require`" to "library + scaffolding tool."
   Worth naming explicitly since every other Monk primitive so far has
   been pure library code.
2. **Command is `monk new APP_NAME`, not `monk init`.** Creates a fresh
   `APP_NAME` directory and scaffolds into it — mirrors `bundle gem NAME`
   / `rails new NAME`, and sidesteps "what does this do to files already
   in my current directory" ambiguity that `init`-style commands carry.
3. **The library class is `Monk::Scaffold`, not `Monk::Init`.** Keeps the
   CLI verb (`new`) and the library noun distinct rather than forcing one
   name to serve both — `Monk::Scaffold.new(dir, postgres: true).write!`
   reads the same whether it's called `new` or `init` from the command
   line.
4. **Templates are static files, copied verbatim — no ERB, no
   interpolation engine.** The generated `App` class is always named
   `App`; nothing in any template needs the project's own name substituted
   in, so there's nothing to template-render. `APP_NAME` is used for
   exactly one thing: naming the destination directory. This cuts an
   entire dependency/design axis (which templating engine, how escaping
   works) that "basic" scaffolding doesn't need.
5. **Base skeleton is persistence-free**: `Gemfile`, `config.ru` (a
   minimal `App < Monk::Base` with one `get("/hello")` route, same shape
   as the README's own quick start), `.ruby-version` (pinned to the same
   version as this repo's own). Mirrors persistence itself being opt-in in
   the library — a new Monk project shouldn't be handed Postgres wiring it
   didn't ask for.
6. **`--postgres` adds exactly what `PLAN-MIGRATIONS.md` Phase 5 hand-wrote
   into `monk-consumer-test`**: `config/persistence.rb`, `bin/console`,
   `bin/setup_db`, `bin/migrate`, and an empty `db/migrate/` directory,
   plus `pg`/`irb` added to the base `Gemfile` template. No demo migration
   is seeded — `db/migrate/` starts genuinely empty, since this is scaffolding
   an *empty* project, not a worked example.
7. **`monk new` refuses to run if `APP_NAME` already exists** — a precise
   error naming the path, never a silent overwrite. Fail fast, per ADR
   0003's spirit, same instinct as `Migrator`'s malformed-filename checks.
8. **No shelling out.** `monk new` never runs `bundle install`, `git
   init`, or anything else on the user's behalf — it only writes files,
   and prints the manual next steps (`cd APP_NAME && bundle install`) the
   same way `monk-consumer-test`'s own README already documents. Keeps the
   seam pure filesystem, trivially testable without a subprocess or
   network access.
9. **The shipped `Gemfile` template says plain `gem "monk"`** (correct for
   once the gem is actually published — see `NOTES-V2.md`'s note that
   RubyGems already has an unrelated dormant gem named `monk`, a rename
   will be needed first). Phase 4's own end-to-end test patches the
   generated `Gemfile` to add `path: "../monk"` itself, as a test-harness
   concern — not something `Monk::Scaffold` does on its own behalf.

## Seams

- **Seam K — `Monk::Scaffold`'s own public API**: given a destination
  directory and a `postgres:` flag, writes the right file set to disk.
  Pure filesystem — no network, no Postgres — tested directly against its
  own interface into a `Dir.mktmpdir`, the same style Phase 1 of
  `PLAN-MIGRATIONS.md` used for file discovery.
- **Seam L — `exe/monk`'s argument parsing/dispatch**: thin CLI wrapper
  turning `ARGV` into a `Monk::Scaffold` call (or a usage error), tested
  by invoking the executable as a real subprocess against a scratch
  directory.
- **Seam M — end-to-end proof**: a freshly `monk new`'d project actually
  resolves `monk` and boots (base variant), and actually serves a request
  round-tripping through Postgres (`--postgres` variant) — the scaffolding
  equivalent of `PLAN-PERSISTENCE.md` Seam H / `PLAN-MIGRATIONS.md` Seam J.

## Phase 1 — Base skeleton writer (Seam K, part 1) — done

1. `Monk::Scaffold.new(dir).write!` creates `dir` (including missing
   parent directories, `mkdir -p`-style) and writes `Gemfile`, `config.ru`,
   `.ruby-version` matching the checked-in templates exactly, byte for
   byte.
2. Raises a precise error naming `dir` if it already exists — never
   silently overwrites whatever's there.
3. The generated `config.ru` is exactly the template's content (verified
   by string equality against the source template file) — actually
   booting it is deliberately left to Phase 4's end-to-end seam, not
   re-proven here.

## Phase 2 — Postgres scaffolding (Seam K, part 2) — done

4. `Monk::Scaffold.new(dir, postgres: true).write!` additionally writes
   `config/persistence.rb`, `bin/console`, `bin/setup_db`, `bin/migrate`,
   and an empty `db/migrate/` directory.
5. `bin/console`, `bin/setup_db`, `bin/migrate` are written executable
   (mode `0755`) — a generated script nobody can run without `chmod +x`
   first is a broken generator.
6. The `postgres: true` `Gemfile` is the base template plus `pg` and
   `irb` — verified as a diff against the base variant's `Gemfile`, not by
   re-asserting the whole file a second time.

## Phase 3 — `exe/monk` CLI (Seam L) — done

7. `exe/monk new APP_NAME` invokes `Monk::Scaffold.new("./APP_NAME").write!`;
   `exe/monk new APP_NAME --postgres` passes `postgres: true`.
8. A missing `APP_NAME`, or a subcommand that isn't `new`, prints usage to
   stderr and exits non-zero — a user typo gets a usage line, not a raw
   Ruby backtrace.
9. `monk.gemspec` declares `spec.bindir = "exe"` / `spec.executables =
   ["monk"]`, and `bundle exec monk new demo_app` works from inside this
   repo's own Bundler context (proves the executable is actually wired up,
   not just present on disk).

## Phase 4 — End-to-end proof (Seam M) — done

10. `monk new` into a disposable scratch directory (not `monk-consumer-test`
    — that one stays the hand-wired reference this plan's templates were
    copied from), `Gemfile` patched to `path: "../monk"` per decision 9,
    `bundle install` run for real, and `bundle exec rackup config.ru`
    actually serves `GET /hello` — proves the base skeleton isn't just
    plausible-looking files but a real bootable app.
11. Same scratch-directory proof for `--postgres`: against a disposable
    `postgres:16` container, `bin/setup_db` then a real request against a
    `/users`-style route (added by hand to the scaffolded `config.ru` for
    this one verification, same as `PLAN-MIGRATIONS.md` Phase 5's
    `monk-consumer-test` route) round-trips correctly.

## Explicitly out of scope for this plan

No code generators inside an existing project (`monk generate
migration/model/...` — project scaffolding only, not ongoing
code-generation tooling), no non-Postgres backend option (mirrors
persistence itself being Postgres-only), no `bundle install`/`git init`
automation (manual steps, printed by the generator's own output), no
interactive prompts (`monk new` takes flags, not a wizard), no custom/
user-supplied template directories (`--template=...`), no "eject" or
upgrade tooling for updating an existing scaffolded app's boilerplate
after the fact, no publishing `monk` to RubyGems (a separate, unrelated
decision — see `NOTES-V2.md`).
