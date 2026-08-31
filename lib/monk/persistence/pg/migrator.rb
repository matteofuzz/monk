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
        end

        private

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
