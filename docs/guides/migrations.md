# Migrations — `Monk::Persistence::Pg::Migrator`

Also opt-in (`require "monk/persistence/pg/migrator"`), and Postgres-only
like the rest of persistence. A migration is a pair of plain `.sql` files —
no DSL, no generator — named `<version>_<name>.up.sql` / `.down.sql`, with
`version` a sortable prefix (a timestamp works well: `20260831120000`):

```
db/migrate/20260831120000_create_widgets.up.sql
db/migrate/20260831120000_create_widgets.down.sql
```

```ruby
migrator = Monk::Persistence::Pg::Migrator.new(db_name: :primary, dir: "db/migrate")

migrator.migrate!              # runs every pending .up.sql, in order, one transaction each
migrator.rollback!             # reverts the most recently applied migration
migrator.rollback!(steps: 3)   # reverts the 3 most recently applied
migrator.pending                # => not-yet-applied versions, ascending
migrator.applied                # => already-applied versions, in the order they ran
```

Applied versions are tracked in a `schema_migrations` table, created
automatically on first use. A failing statement rolls back just that
migration's transaction and halts the run — later pending migrations are
never attempted. Migrations never run implicitly (no hook into
`Monk.boot`/`.freeze!`); running them is an explicit step.

`monk add postgres` writes that step: `bin/migrate` (`bin/migrate`,
`bin/migrate rollback [N]`, `bin/migrate status`) and `bin/setup_db`,
which migrates the database `DB_NAME` names once it exists (the app's
`SETUP.md` has the command that creates it). Modules that need tables
(`auth`, `jobs`, `push`, `presence`) add their migrations to
`db/migrate/`, versioned with the time they're added.
