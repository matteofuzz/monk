require_relative "../pg"
require_relative "../../malformed_migration_error"

module Monk
  module Persistence
    module Pg
      # Applies/rolls back versioned .sql file pairs against a registered
      # Monk::Persistence::Pg database. Deliberately not a DSL: each
      # <version>_<name>.up.sql / .down.sql pair is sent to Postgres
      # verbatim -- see PLAN-MIGRATIONS.md for the full rationale.
      class Migrator
        FILENAME = /\A(\d+)_(.+)\.(up|down)\.sql\z/

        Migration = Struct.new(:version, :name, :up_path, :down_path)

        attr_reader :migrations

        def initialize(db_name:, dir: "db/migrate")
          @db_name = db_name
          @dir = dir
          @migrations = load_migrations
          @schema_migrations_ready = false
        end

        # Runs every pending .up.sql (its version absent from
        # schema_migrations) in ascending order, each inside its own
        # transaction, recording the version only after that transaction
        # commits. A failing statement rolls back just that migration and
        # halts the run -- later pending migrations are never attempted.
        # Returns the versions actually applied.
        def migrate!
          applied = []

          Monk::Persistence::Pg.checkout(@db_name) do |conn|
            ensure_schema_migrations_table(conn)
            already_applied = applied_versions(conn)

            migrations.reject { |m| already_applied.include?(m.version) }.each do |m|
              conn.transaction do
                conn.exec(File.read(m.up_path))
                conn.exec_params("INSERT INTO schema_migrations (version) VALUES ($1)", [m.version])
              end
              applied << m.version
            end
          end

          applied
        end

        # Runs .down.sql for the `steps` most recently applied migrations,
        # most-recent-first, each inside its own transaction, removing the
        # version from schema_migrations only after that transaction
        # commits. `steps` beyond the number actually applied rolls back
        # everything and stops cleanly. Returns the versions reverted.
        def rollback!(steps: 1)
          reverted = []

          Monk::Persistence::Pg.checkout(@db_name) do |conn|
            ensure_schema_migrations_table(conn)

            recently_applied(conn, steps).each do |version|
              migration = migrations.find { |m| m.version == version }
              unless migration
                raise Monk::MalformedMigrationError,
                  "applied migration #{version.inspect} has no matching .down.sql file on disk"
              end

              conn.transaction do
                conn.exec(File.read(migration.down_path))
                conn.exec_params("DELETE FROM schema_migrations WHERE version = $1", [version])
              end
              reverted << version
            end
          end

          reverted
        end

        # Not-yet-applied versions, ascending, with no side effects.
        def pending
          Monk::Persistence::Pg.checkout(@db_name) do |conn|
            ensure_schema_migrations_table(conn)
            already_applied = applied_versions(conn)
            migrations.reject { |m| already_applied.include?(m.version) }.map(&:version)
          end
        end

        # Already-applied versions, in the order they were applied.
        def applied
          Monk::Persistence::Pg.checkout(@db_name) do |conn|
            ensure_schema_migrations_table(conn)
            applied_versions(conn)
          end
        end

        private

        def recently_applied(conn, steps)
          conn.exec_params(
            "SELECT version FROM schema_migrations ORDER BY applied_at DESC, version DESC LIMIT $1", [steps]
          ).map { |row| row["version"] }
        end

        # Checks existence via information_schema first, rather than relying
        # on CREATE TABLE IF NOT EXISTS's own "already exists, skipping"
        # NOTICE -- confusing noise on every call once the table exists.
        # Memoized per instance since a single Migrator's checks/commands
        # often chain multiple calls together (e.g. bin/migrate status
        # calling #applied then #pending).
        def ensure_schema_migrations_table(conn)
          return if @schema_migrations_ready

          exists = conn.exec(
            "SELECT 1 FROM information_schema.tables WHERE table_name = 'schema_migrations'"
          ).ntuples.positive?

          conn.exec(<<~SQL) unless exists
            CREATE TABLE schema_migrations (
              version TEXT PRIMARY KEY,
              applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
          SQL

          @schema_migrations_ready = true
        end

        def applied_versions(conn)
          conn.exec("SELECT version FROM schema_migrations ORDER BY applied_at, version").map { |row| row["version"] }
        end

        def load_migrations
          by_version = {}

          Dir.glob(File.join(@dir, "*.sql")).sort.each do |path|
            match = FILENAME.match(File.basename(path))
            raise Monk::MalformedMigrationError,
              "#{path.inspect} doesn't match the <version>_<name>.(up|down).sql convention" unless match

            version, name, direction = match.captures
            migration = (by_version[version] ||= Migration.new(version, name))

            if migration.name != name
              raise Monk::MalformedMigrationError,
                "version #{version.inspect} names two different migrations " \
                "(#{migration.name.inspect} vs #{name.inspect})"
            end

            direction == "up" ? migration.up_path = path : migration.down_path = path
          end

          ordered = by_version.values.sort_by { |m| m.version.to_i }
          ordered.each do |m|
            next if m.up_path && m.down_path

            missing = m.up_path ? "down" : "up"
            raise Monk::MalformedMigrationError,
              "migration #{m.version}_#{m.name} is missing its .#{missing}.sql file"
          end

          ordered
        end
      end
    end
  end
end
