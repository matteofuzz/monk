require "monk"
require "monk/persistence/pg"

Monk::Persistence::Pg.register(:primary,
  host: ENV.fetch("DB_HOST", "127.0.0.1"),
  port: ENV.fetch("DB_PORT", "5432").to_i,
  user: ENV.fetch("DB_USER", "postgres"),
  password: ENV.fetch("DB_PASSWORD", "postgres"),
  dbname: ENV.fetch("DB_NAME", "app_development"),
)
