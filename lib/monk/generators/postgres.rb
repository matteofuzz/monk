# Postgres persistence and migrations (Monk::Persistence::Pg).
Monk::Generator.define(:postgres) do
  summary "Postgres persistence and migrations"
  installed_if "config/persistence.rb"

  copy "config/persistence.rb", "db/migrate/.keep", role: :wiring
  copy "bin/console", "bin/setup_db", "bin/migrate", role: :wiring, executable: true
  copy "app/routes/postgres.rb", role: :example
  copy "test/persistence_test.rb", role: :test

  gem %(gem "pg", "~> 1.6" # 1.6+ ships precompiled, libpq included: no system packages)
  gem %(gem "irb")
  database = { "DB_HOST" => "127.0.0.1", "DB_PORT" => "5432", "DB_USER" => "postgres", "DB_PASSWORD" => "postgres" }
  env :development, database.merge("DB_NAME" => ->(app) { "#{app}_development" })
  env :test, database.merge("DB_NAME" => ->(app) { "#{app}_test" })
  env :example, database.merge("DB_NAME" => ->(app) { "#{app}_development" })

  service :postgres, check: "pg_isready -h 127.0.0.1 -p 5432", setup: "SETUP.md#postgres"
  next_step "start Postgres and create the databases (SETUP.md › postgres)"
  setup_section "postgres/setup.md"
  agents_section "postgres/agents.md"
  example "postgres-model", todo: "uncomment, then move the table to a migration and the model to app/models/"
end
