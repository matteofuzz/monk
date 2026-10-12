# Upgrading an app to a new Monk

`monk new` and `monk add` write an app with the current Monk, but they
don't update an app written by an earlier one: `monk add` does nothing
for a module the app already has. So each release that changes what an
app needs lists the steps here: the files to copy, the lines to add, and
the migrations to add.

`monk help MODULE --file PATH` prints this Monk's version of any file a
module writes, so you can copy it or compare it with yours. For a
migration, any timestamp in the name works
(`db/migrate/x_create_recurring_tables.up.sql`): copy it under a new
timestamp of your own, so it runs after your existing migrations.

An app made with the release named in a section needs none of its steps.

## 0.22

First update the gem: `bundle update monkrb` (the `Gemfile`'s
`"~> 0.21"` already allows 0.22).

### Recurring jobs (apps with jobs)

Recurring jobs ([`jobs.md`](jobs.md#recurring-jobs)) need a table and a
file loaded after `app/`. Until the migration is applied, an app that
declares a recurring task can't start `bin/jobs` (it says which migration
is missing), and the app's tests that call `Monk::Jobs.clear!` fail on the
missing table, with or without recurring tasks.

1. **Load `config/recurring.rb`.** Add these lines to `config/load.rb`,
   after the loop that loads `app/` (`monk help base --file config/load.rb`
   shows where):
   ```ruby
   # With jobs (monk add jobs), the schedules of recurring jobs. Last, because
   # each one names a job class from app/jobs/.
   recurring = File.expand_path("recurring.rb", __dir__)
   require recurring if File.exist?(recurring)
   ```
2. **Add `config/recurring.rb`**, where tasks are declared:
   `monk help jobs --file config/recurring.rb > config/recurring.rb`.
3. **Add the migration**, both halves, under a new timestamp, then apply
   it to every database the app uses, the test one included:
   ```bash
   ts=$(date -u +%Y%m%d%H%M%S)
   monk help jobs --file db/migrate/x_create_recurring_tables.up.sql > db/migrate/${ts}_create_recurring_tables.up.sql
   monk help jobs --file db/migrate/x_create_recurring_tables.down.sql > db/migrate/${ts}_create_recurring_tables.down.sql
   bin/migrate && DB_NAME=my_app_test bin/migrate
   ```
   If the queue has a database of its own
   ([`jobs.md`](jobs.md#moving-the-queue-to-its-own-database)), the
   migration goes with the jobs migrations, applied to that database.
4. **Optionally**, the new parts of the jobs sections of `SETUP.md` and
   `AGENTS.md` ("Recurring jobs", and the recurring calls and pitfalls).
   Monk's versions are in the gem, under
   `$(bundle info monkrb --path)/lib/monk/templates/jobs/`: `setup.md` and
   `agents.md`.
