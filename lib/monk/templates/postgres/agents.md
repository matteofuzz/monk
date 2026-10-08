## postgres

**Where:** `config/persistence.rb` registers the `:primary` connection from
`DB_*`. Migrations: `db/migrate/<timestamp>_<name>.up.sql` and `.down.sql`,
plain SQL. Models: `app/models/`.

**Main calls:** a model is `class Note < Monk::Persistence::Pg::Model` with
`self.db_name = :primary` and `self.table_name = "notes"`; then
`Note.create(...)`, `.find(id)`, `.where(...)`, `.update(id, ...)`,
`.delete(id)`. Rows are plain Symbol-keyed Hashes: no ORM, no associations.
Raw SQL: `Monk::Persistence::Pg.checkout(:primary) { |conn| conn.exec_params(sql, params) }`.
Commands: `bin/setup_db` (apply pending migrations), `bin/migrate
[migrate|rollback N|status]`, `bin/console`.

**Test:** `test/persistence_test.rb` connects to the test database. Tests use
`.env.test`'s `DB_NAME`: migrate it with `DB_NAME={{app}}_test bin/setup_db`.

**Pitfalls:**
- Models and connections must exist before `Monk.boot`: put models in
  `app/models/`, never define one inside a route.
- Never interpolate params into SQL: use `exec_params` with `$1`, `$2`.
- A new migration gets a new, later timestamp. Never edit one that's
  already applied.

**Examples:** `postgres-model` in `app/routes/postgres.rb`.
