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
        wire_config_ru!
        write_env_files!
        write_setup_md!
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

    # config.ru ships in BASE_FILES unconditionally (it has to -- it's the
    # only rackup entrypoint), so --postgres/--auth can't gate whether it
    # exists, only what it requires. Unlike BASE_FILES/POSTGRES_FILES/
    # AUTH_FILES, this is a post-write edit rather than a verbatim copy --
    # the alternative (a second, fuller config.ru template per flag
    # combination) would duplicate the whole file for one line of diff.
    def wire_config_ru!
      path = File.join(@dir, "config.ru")
      settings_require = %(require_relative "config/settings"\n)
      target = @auth ? "config/auth" : "config/persistence" # config/auth.rb itself require_relative "persistence"

      content = File.read(path)
      raise "config.ru wiring failed: #{settings_require.inspect} not found" unless content.include?(settings_require)

      File.write(path, content.sub(settings_require, "#{settings_require}require_relative \"#{target}\"\n"))
    end

    # .env/.env.test/.env.example are the other deliberate exception to
    # "templates are static files, copied verbatim" (see the class comment
    # above): DB_NAME needs this app's own directory name in it -- the one
    # piece of scaffold-wide content that's actually per-project -- so
    # these are composed here instead of read from disk. .env/.env.test are
    # gitignored (see base/.gitignore); .env.example is the tracked
    # placeholder that file explicitly carves out.
    def write_env_files!
      app_name = File.basename(@dir)

      dev = pg_env_lines("#{app_name}_development")
      test = pg_env_lines("#{app_name}_test")
      example = pg_env_lines("#{app_name}_development")

      if @auth
        dev << "AUTH_SECRET=change-me-dev-secret"
        test << "AUTH_SECRET=change-me-test-secret"
        example << "AUTH_SECRET=change-me"
      end

      # REDIS_URL is deliberately absent from .env.test -- only a test that
      # actually exercises RedisFanout needs it, unlike DB_NAME/AUTH_SECRET
      # which every test touching persistence/auth needs.
      if @redis
        dev << "REDIS_URL=redis://localhost:6379/0"
        example << "REDIS_URL=redis://localhost:6379/0"
      end

      write_lines(".env", dev)
      write_lines(".env.test", test)
      write_lines(".env.example", example)
    end

    def pg_env_lines(dbname)
      [
        "DB_HOST=127.0.0.1",
        "DB_PORT=5432",
        "DB_USER=postgres",
        "DB_PASSWORD=postgres",
        "DB_NAME=#{dbname}",
      ]
    end

    def write_lines(relative_path, lines)
      File.write(File.join(@dir, relative_path), "#{lines.join("\n")}\n")
    end

    def write_setup_md!
      File.write(File.join(@dir, "SETUP.md"), setup_md_content)
    end

    def setup_md_content
      app_name = File.basename(@dir)

      <<~MARKDOWN
        # Setting up #{app_name} (dev, then test)

        `config.ru`, `.env`, and `.env.test` are already wired up by `monk new`
        -- `config.ru` requires `config/#{@auth ? "auth" : "persistence"}` before `class App`, and
        `.env`/`.env.test` are pre-filled with a database name derived from
        this project's directory (`#{app_name}_development` / `#{app_name}_test`), not the
        generic `app_development` fallback baked into `config/persistence.rb`
        itself. Adjust `DB_HOST`/`DB_USER`/`DB_PASSWORD` in both files if your
        local Postgres doesn't use the `postgres`/`postgres` defaults.

        `MONK_ENV` and the database name are two separate, unlinked knobs --
        setting `MONK_ENV=test` does not by itself change which database you
        connect to. Only `DB_NAME` (here, via `.env`/`.env.test`) does that.

        ## Dev environment, first run

        ```bash
        bundle install
        ```

        ### 1. Start Postgres#{@redis ? " and Redis" : ""}

        Check first whether a Postgres#{@redis ? "/Redis" : ""} container is already running from another
        project -- starting a second one bound to the same host port fails with
        `port is already allocated`:

        ```bash
        docker ps
        ```

        If something's already listening on 5432#{@redis ? "/6379" : ""}, reuse it instead of starting a new
        one -- point `.env`/`.env.test`'s `DB_HOST`/`DB_PORT`#{@redis ? "/`REDIS_URL`" : ""} at it, and use its
        actual `DB_USER`/`DB_PASSWORD` rather than the generated defaults.
        Otherwise, start #{@redis ? "fresh containers" : "a fresh container"}:

        ```bash
        docker run --rm -d -p 5432:5432 -e POSTGRES_PASSWORD=postgres --name #{app_name}_pg postgres:16
        #{"docker run --rm -d -p 6379:6379 --name #{app_name}_redis redis:7\n" if @redis}```

        ### 2. Create the dev database

        Plain `createdb` connects over the local Unix socket by default, which a
        Docker container never provides -- use `-h`/`-p` to force a TCP
        connection, or run `createdb` from inside the container instead to avoid
        passing a password on the command line:

        ```bash
        # via TCP (adjust -h/-p/-U to match whatever's actually running):
        PGPASSWORD=postgres createdb -h 127.0.0.1 -p 5432 -U postgres #{app_name}_development

        # or, from inside an existing Postgres container, as the postgres user:
        docker exec -u postgres <container_name> createdb #{app_name}_development
        ```

        ### 3. Run migrations

        ```bash
        bin/setup_db
        ```

        ### 4. Run it

        ```bash
        bin/server              # HTTP app on :9292
        bin/websocket_server    # WS chat process on :9293, in another terminal
        ```
        #{auth_or_redis_confirmation_note}
        ## Test environment

        ### 1. Create the test database

        ```bash
        PGPASSWORD=postgres createdb -h 127.0.0.1 -p 5432 -U postgres #{app_name}_test

        # or, from inside an existing Postgres container, as the postgres user:
        docker exec -u postgres <container_name> createdb #{app_name}_test
        ```

        ### 2. Migrate the test database

        ```bash
        DB_NAME=#{app_name}_test bin/setup_db
        ```

        ### 3. Add a test framework and run it

        `monk new` scaffolds no test framework at all -- this is the minimum to
        get `bundle exec rake test` working, using Minitest (matches `monk`'s
        own suite):

        **Gemfile** -- add:

        ```ruby
        group :test do
          gem "minitest"
          gem "rake"
        end
        ```

        **test/test_helper.rb** -- loads `.env.test` explicitly (not the default
        dotenv-in-`config/settings.rb` path, which only loads plain `.env`), then
        wires up the app config the same way `config.ru` does:

        ```ruby
        $LOAD_PATH.unshift(File.expand_path("..", __dir__))

        ENV["MONK_ENV"] ||= "test"

        require "dotenv"
        Dotenv.load(File.expand_path(".env.test", __dir__ + "/.."))

        require "minitest/autorun"
        require_relative "../config/settings"
        require_relative "../config/#{@auth ? "auth" : "persistence"}"
        ```

        **Rakefile**:

        ```ruby
        require "rake/testtask"

        Rake::TestTask.new do |t|
          t.libs << "test"
          t.pattern = "test/**/*_test.rb"
        end

        task default: :test
        ```

        **test/persistence_test.rb** -- a real smoke test, not just a
        connectivity check:

        ```ruby
        require_relative "test_helper"

        class PersistenceTest < Minitest::Test
        #{sample_test_body}
        end
        ```

        Then:

        ```bash
        bundle install
        bundle exec rake test
        ```

        `test/test_helper.rb` sets `MONK_ENV=test` itself (so `Monk.env.test?`
        reads correctly if the app ever branches on it) and loads `.env.test` for
        the actual connection details -- but per the note at the top, those are
        two separate knobs: `MONK_ENV` doesn't affect `DB_NAME` on its own,
        `.env.test`'s `DB_NAME=#{app_name}_test` is what actually points tests at
        the right database.
      MARKDOWN
    end

    def auth_or_redis_confirmation_note
      return "" unless @auth || @redis

      flags = [("authenticate: true" if @auth), ("redis fan-out: on" if @redis)].compact.join(", ")
      visible = if @auth && @redis
        "both `AUTH_SECRET` and `REDIS_URL` are"
      else
        @auth ? "`AUTH_SECRET` is" : "`REDIS_URL` is"
      end

      "\n`bin/websocket_server`'s startup line should print `#{flags}` once " \
        "#{visible} visible to it -- that confirms everything's actually wired up.\n"
    end

    def sample_test_body
      if @auth
        <<~RUBY.chomp.gsub(/^/, "  ")
          def test_connects_to_the_test_database_and_sees_the_auth_tables
            Monk::Persistence::Pg.checkout(:primary) do |conn|
              result = conn.exec("SELECT to_regclass('login_tokens') IS NOT NULL AS present")
              assert_equal true, result[0]["present"]
            end
          end
        RUBY
      else
        <<~RUBY.chomp.gsub(/^/, "  ")
          def test_connects_to_the_test_database
            Monk::Persistence::Pg.checkout(:primary) do |conn|
              assert_equal "1", conn.exec("SELECT 1").getvalue(0, 0)
            end
          end
        RUBY
      end
    end

    def write_file(relative_path, template_path, executable: false)
      destination = File.join(@dir, relative_path)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(File.join(TEMPLATES_DIR, template_path), destination)
      File.chmod(0o755, destination) if executable
    end
  end
end
