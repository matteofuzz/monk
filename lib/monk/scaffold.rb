require "fileutils"

require_relative "errors"

module Monk
  # Writes a new Monk project's skeleton to disk. Templates are static
  # files, copied verbatim -- nothing here needs the project's own name
  # substituted in, so there's no templating engine involved. See
  # PLAN-INIT.md for the full design.
  class Scaffold
    TEMPLATES_DIR = File.expand_path("templates", __dir__)

    BASE_FILES = {
      "Gemfile" => "base/Gemfile",
      "config.ru" => "base/config.ru",
      "config/settings.rb" => "base/config/settings.rb",
      ".ruby-version" => "base/.ruby-version",
      "bin/server" => "base/bin/server",
      "views/layouts/app.erb" => "base/views/layouts/app.erb",
      "views/index.erb" => "base/views/index.erb",
      "public/css/app.css" => "base/public/css/app.css",
      "public/js/app.js" => "base/public/js/app.js",
    }.freeze

    POSTGRES_FILES = {
      "config/persistence.rb" => "postgres/config/persistence.rb",
      "bin/console" => "postgres/bin/console",
      "bin/setup_db" => "postgres/bin/setup_db",
      "bin/migrate" => "postgres/bin/migrate",
    }.freeze

    AUTH_FILES = {
      "config/auth.rb" => "auth/config/auth.rb",
      "db/migrate/00000000000001_create_auth_tables.up.sql" => "auth/db/migrate/00000000000001_create_auth_tables.up.sql",
      "db/migrate/00000000000001_create_auth_tables.down.sql" => "auth/db/migrate/00000000000001_create_auth_tables.down.sql",
    }.freeze

    EXECUTABLE_FILES = %w[bin/server bin/console bin/setup_db bin/migrate].freeze

    # auth: implies postgres -- Monk::Auth is Postgres-only (lib/monk/auth.rb
    # subclasses Monk::Persistence::Pg::Model), so there's no combination
    # where an app gets Auth without also getting the persistence scaffold.
    def initialize(dir, postgres: false, auth: false)
      @dir = dir
      @auth = auth
      @postgres = postgres || auth
    end

    def write!
      raise Monk::ScaffoldExistsError, "#{@dir} already exists" if File.exist?(@dir)

      FileUtils.mkdir_p(@dir)
      BASE_FILES.each { |relative, template| write_file(relative, template, executable: EXECUTABLE_FILES.include?(relative)) }

      if @postgres
        POSTGRES_FILES.each { |relative, template| write_file(relative, template, executable: EXECUTABLE_FILES.include?(relative)) }
        FileUtils.mkdir_p(File.join(@dir, "db/migrate"))
        append_postgres_gems
      end

      return unless @auth

      AUTH_FILES.each { |relative, template| write_file(relative, template) }
    end

    private

    def append_postgres_gems
      extra = File.read(File.join(TEMPLATES_DIR, "postgres/Gemfile.extra"))
      File.write(File.join(@dir, "Gemfile"), "\n#{extra}", mode: "a")
    end

    def write_file(relative_path, template_path, executable: false)
      destination = File.join(@dir, relative_path)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(File.join(TEMPLATES_DIR, template_path), destination)
      File.chmod(0o755, destination) if executable
    end
  end
end
