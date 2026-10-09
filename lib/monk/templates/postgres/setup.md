## postgres

`.env` and `.env.test` point at a local Postgres (`DB_*`), with database
names taken from this app's directory: `{{app}}_development` and
`{{app}}_test`. `MONK_ENV=test` doesn't change the database: only `DB_NAME`
does, and `test/test_helper.rb` takes it from `.env.test`.

### Start Postgres

Check first whether one is already running (`docker ps`): a second
container on the same port fails with "port is already allocated". Either
point `DB_HOST`/`DB_PORT`/`DB_USER`/`DB_PASSWORD` in `.env` and `.env.test`
at the running one, or start one:

```bash
docker run --rm -d -p 5432:5432 -e POSTGRES_PASSWORD=postgres --name {{app}}_pg postgres:16
```

### Create the databases and migrate them

```bash
PGPASSWORD=postgres createdb -h 127.0.0.1 -p 5432 -U postgres {{app}}_development
PGPASSWORD=postgres createdb -h 127.0.0.1 -p 5432 -U postgres {{app}}_test
bin/setup_db
DB_NAME={{app}}_test bin/setup_db
```

`createdb` without `-h` uses a Unix socket, which a container doesn't
provide. Run both `bin/setup_db` lines again after adding a migration.

### Check it works

1. `bundle exec rake test` runs `test/persistence_test.rb`, which connects
   to the test database.
2. By hand: `bin/console` opens IRB with the app's configs and models
   loaded; `Monk::Persistence::Pg.checkout(:primary) { |conn| conn.exec("SELECT 1").values }`
   answers `[[1]]`. `bin/migrate status` lists applied and pending
   migrations.
