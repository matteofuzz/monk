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
      ".gitignore" => "base/.gitignore",
      "bin/server" => "base/bin/server",
      "bin/websocket_server" => "base/bin/websocket_server",
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

    EXECUTABLE_FILES = %w[bin/server bin/websocket_server bin/console bin/setup_db bin/migrate].freeze

    # auth: implies postgres -- Monk::Auth is Postgres-only (lib/monk/auth.rb
    # subclasses Monk::Persistence::Pg::Model), so there's no combination
    # where an app gets Auth without also getting the persistence scaffold.
    #
    # redis: is unrelated to both -- it doesn't imply, and isn't implied by,
    # postgres or auth. Unlike them it adds no files of its own, just a
    # Gemfile line: bin/websocket_server (always present, see BASE_FILES
    # above -- WebSocket needs no external service, so unlike Postgres/Redis
    # it isn't gated behind a flag at all) checks ENV["REDIS_URL"] at boot
    # and only then requires "redis", so the gem has to already be in the
    # bundle for that to work.
    def initialize(dir, postgres: false, auth: false, redis: false)
      @dir = dir
      @auth = auth
      @postgres = postgres || auth
      @redis = redis
    end

    def write!
      raise Monk::ScaffoldExistsError, "#{@dir} already exists" if File.exist?(@dir)

      FileUtils.mkdir_p(@dir)
      BASE_FILES.each { |relative, template| write_file(relative, template, executable: EXECUTABLE_FILES.include?(relative)) }

      if @postgres
        POSTGRES_FILES.each { |relative, template| write_file(relative, template, executable: EXECUTABLE_FILES.include?(relative)) }
        FileUtils.mkdir_p(File.join(@dir, "db/migrate"))
        append_gemfile_extra("postgres/Gemfile.extra")
      end

      append_gemfile_extra("redis/Gemfile.extra") if @redis

      return unless @auth

      AUTH_FILES.each { |relative, template| write_file(relative, template) }
    end

    private

    def append_gemfile_extra(template_path)
      extra = File.read(File.join(TEMPLATES_DIR, template_path))
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
