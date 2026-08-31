# Monk schema & migrations — implementation plan

Branch: `main_dev/25-add-a-basic-support-for-schema-and-migrations-management`
(issue #25). Depends on: `Monk::Persistence::Pg` (`main`, done). No companion design doc
yet — the decisions below are locked in here directly, since the surface
is small enough not to need a separate rationale doc the way persistence
did.

Like `PLAN.md` and `PLAN-PERSISTENCE.md`, this develops in small, gradual,
red → green cycles. Each numbered step is one vertical slice: one failing
test against its seam, then the minimum code to pass it.

## Decisions locked in before Phase 1

1. **Postgres only, raw SQL files, no DSL.** Mirrors `Monk::Persistence::Pg::Model`'s
   own stance: Monk doesn't own a schema-generating abstraction
   (`create_table do |t| ... end`), just enough mechanics to track and run
   plain `.sql` files in order. Multi-backend migrations are out of scope
   until there's a second backend to be agnostic across.
2. **One file per direction, not one file with markers.** A migration is a
   pair — `<version>_<name>.up.sql` / `<version>_<name>.down.sql` — rather
   than a single file split on `-- up`/`-- down` comments. No parsing
   beyond a filename regex; each file's contents are sent to Postgres
   verbatim.
3. **Version is a sortable timestamp prefix** (`YYYYMMDDHHMMSS`, e.g.
   `20260831120000_create_widgets.up.sql`), Rails-migration-style — cheap
   collision avoidance, orders correctly as both a string and a number.
4. **Applied versions are tracked in a `schema_migrations` table**
   (`version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT
   now()`), created on first run (`CREATE TABLE IF NOT EXISTS`) rather than
   requiring it to pre-exist.
5. **The migrator reuses `Monk::Persistence::Pg`'s existing
   registry/checkout, not a standalone connection.** A migration run is
   just another caller of `Monk::Persistence::Pg.checkout(db_name)` — same
   `register`'d config an app's `Model`s already use, no separate
   connection-string plumbing to invent.
6. **Migrations never run implicitly.** No hook into `Monk.boot`/
   `.freeze!` — running migrations is an explicit, separate step (a
   script/task the app author invokes), kept out of the request-serving
   path entirely. This is also why none of this needs Ractor-shareability
   work: it runs once, in the main Ractor, before any worker exists.
7. **Each migration file runs inside its own transaction** (via `pg`'s
   `PG::Connection#transaction`), and its version is recorded only after
   that file's transaction commits — a failing statement rolls back just
   that file's changes and halts the run before later files execute.

## Seams

- **Seam I — `Monk::Persistence::Pg::Migrator`'s own public API**: file
  discovery/ordering, applying pending migrations, rolling back, and
  status introspection — tested directly against its own interface
  (mirrors how `PLAN-PERSISTENCE.md` Seam E tested `Monk::Persistence::Pg`
  itself), against a real Postgres (there's no meaningful fake for "ran
  this SQL file").
- **Seam J — consumer-facing entrypoint**: a runnable script in
  `monk-consumer-test` wrapping the `Migrator`, the persistence equivalent
  of `PLAN-PERSISTENCE.md` Seam H — proves the gem is usable from outside
  the repo, not just against its own test suite.

## Phase 1 — Migration file discovery (Seam I, part 1) — done

1. `Migrator.new(db_name:, dir:)` (default `dir:` "db/migrate") lists
   `<version>_<name>.up.sql` / `.down.sql` pairs found in `dir`.
2. A version is parsed from the filename prefix; a malformed name (no
   numeric version prefix, an `.up.sql` with no matching `.down.sql` or
   vice versa) raises a precise error naming the offending file at
   `Migrator.new` time — fail fast, per ADR 0003's spirit, rather than
   only surfacing the problem mid-run.
3. Discovered migrations are exposed in ascending version order,
   regardless of the directory listing's own order.

## Phase 2 — Applying migrations (Seam I, part 2) — done

4. `Migrator#migrate!` creates `schema_migrations` on first use if it
   doesn't already exist (`CREATE TABLE IF NOT EXISTS`).
5. `Migrator#migrate!` runs every pending `.up.sql` (its version absent
   from `schema_migrations`) in ascending order, recording the version
   immediately after that file's transaction commits, and returns the list
   of versions it actually applied.
6. A failing statement partway through one file's SQL rolls back that
   file's transaction and halts the run — later pending files are not
   attempted, and the failed file's version is not recorded. Verify via a
   deliberately broken `.up.sql` (references a nonexistent column) in a
   two-migration fixture set.
7. Calling `Migrator#migrate!` again with nothing pending is a no-op:
   returns `[]`, issues no `INSERT`s.

## Phase 3 — Rolling back (Seam I, part 3) — done

8. `Migrator#rollback!(steps: 1)` runs `.down.sql` for the most recently
   applied migration(s), most-recent-first, removing each from
   `schema_migrations` only after its down file's transaction commits.
9. `Migrator#rollback!` raises a precise error naming the version if an
   applied migration has no matching `.down.sql` on disk — nothing to run
   to reverse it.
10. `steps:` greater than the number of applied migrations rolls back
    everything applied and stops cleanly (not an error).

## Phase 4 — Status introspection (Seam I, part 4) — done

11. `Migrator#pending` returns not-yet-applied versions in ascending
    order, with no side effects (dry-run visibility before calling
    `migrate!`).
12. `Migrator#applied` returns already-applied versions in the order
    `schema_migrations` recorded them.

## Phase 5 — Consumer-facing entrypoint (Seam J) — done

13. Add `bin/migrate` to `monk-consumer-test` (`migrate` / `rollback [N]` /
    `status` subcommands over `Monk::Persistence::Pg::Migrator`), reusing
    the same `config/persistence.rb` registration `bin/console`/
    `config.ru` already share — not part of the `monk` gem itself, mirrors
    how models and other app-specific wiring already live with the
    consumer app rather than the library.
14. Verified manually against a disposable `postgres:16` container: a
    `create_users` migration pair takes the place of the hand-run
    `db/schema.sql` from `PLAN-PERSISTENCE.md` Phase 6 — `bin/migrate` run
    twice is idempotent, `bin/migrate rollback` cleanly drops what it
    added, and `GET /users` still round-trips correctly afterward.

## Explicitly out of scope for this plan

No schema dump/load (a generated "current schema" snapshot file, à la
Rails' `schema.rb`), no migration generator/scaffolding (`monk generate
migration ...`), no multi-backend migrations (Postgres only, same as
persistence itself), no DSL or query-builder for writing migrations (raw
SQL only, same stance as `Model`), no locking/coordination for concurrent
migration runs (assumes one runner at a time, not multiple deploys racing
each other), no automatic migration-on-boot, no data-loss guards on
destructive down-migrations, no seed-data tooling.
