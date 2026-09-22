require "fileutils"

require_relative "errors"

module Monk
  # Writes a new Monk project's skeleton to disk. Templates are static
  # files, copied verbatim -- nothing here needs the project's own name
  # substituted in, so there's no templating engine involved. See
  # docs/history/plan-init.md for the full design.
  class Scaffold
    TEMPLATES_DIR = File.expand_path("templates", __dir__)

    BASE_FILES = {
      "Gemfile" => "base/Gemfile",
      "config.ru" => "base/config.ru",
      "config/settings.rb" => "base/config/settings.rb",
      ".ruby-version" => "base/.ruby-version",
      ".gitignore" => "base/.gitignore",
      ".dockerignore" => "base/.dockerignore",
      "Dockerfile" => "base/Dockerfile",
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

    # The pg gem's native extension needs libpq -- the base Dockerfile has
    # no system packages at all (kino is a precompiled platform gem), so
    # --postgres/--auth swap in a Dockerfile that adds libpq-dev/libpq5
    # instead of patching one image for every combination.
    POSTGRES_OVERRIDES = {
      "Dockerfile" => "postgres/Dockerfile",
    }.freeze

    AUTH_FILES = {
      "config/auth.rb" => "auth/config/auth.rb",
      "db/migrate/00000000000001_create_auth_tables.up.sql" => "auth/db/migrate/00000000000001_create_auth_tables.up.sql",
      "db/migrate/00000000000001_create_auth_tables.down.sql" => "auth/db/migrate/00000000000001_create_auth_tables.down.sql",
    }.freeze

    # --live: Monk::Live's demo (a counter whose open tabs update when
    # another request changes it). These replace three base files outright
    # rather than patching them -- a live config.ru and index are different
    # files, not one line of diff -- and add two. config.ru's first line stays
    # the settings require, so --postgres/--auth wiring still finds it.
    LIVE_OVERRIDES = {
      "config.ru" => "live/config.ru",
      "bin/websocket_server" => "live/bin/websocket_server",
      "views/index.erb" => "live/views/index.erb",
    }.freeze

    LIVE_FILES = {
      "config/live.rb" => "live/config/live.rb",
      "views/live/_hits.erb" => "live/views/live/_hits.erb",
    }.freeze

    # Where the client runtime lands in the app's public root (an app serves
    # it like any other static file; its files import each other by relative
    # path, so they stay together in one directory).
    LIVE_CLIENT_DIR = "public/js/monk_live".freeze

    LIVE_HEAD = <<~HTML.gsub(/^/, "    ").freeze
      <meta name="monk-live-url" content="<%= settings[:live_ws_url] %>">
      <script type="module" src="<%= asset_path "/js/monk_live/monk_live.js" %>"></script>
    HTML

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
    #
    # live: implies redis: -- bin/server and bin/websocket_server are separate
    # processes, so an update published by one only reaches a socket held by
    # the other through Redis.
    def initialize(dir, postgres: false, auth: false, redis: false, live: false)
      @dir = dir
      @auth = auth
      @postgres = postgres || auth
      @live = live
      @redis = redis || live
    end

    def write!
      raise Monk::ScaffoldExistsError, "#{@dir} already exists" if File.exist?(@dir)

      FileUtils.mkdir_p(@dir)
      base_files = BASE_FILES
      base_files = base_files.merge(LIVE_OVERRIDES) if @live
      base_files = base_files.merge(POSTGRES_OVERRIDES) if @postgres
      base_files.each { |relative, template| write_file(relative, template, executable: EXECUTABLE_FILES.include?(relative)) }
      write_live! if @live

      if @postgres
        POSTGRES_FILES.each { |relative, template| write_file(relative, template, executable: EXECUTABLE_FILES.include?(relative)) }
        FileUtils.mkdir_p(File.join(@dir, "db/migrate"))
        append_gemfile_extra("postgres/Gemfile.extra")
        wire_config_ru!
      end

      append_gemfile_extra("redis/Gemfile.extra") if @redis

      # --postgres and --redis are the two flags with anything worth
      # putting in an env file (a database, a REDIS_URL) -- the base
      # skeleton alone has nothing to configure this way.
      if @postgres || @redis
        write_env_files!
        uncomment_dotenv!
      end

      AUTH_FILES.each { |relative, template| write_file(relative, template) } if @auth

      # Every combination of flags gets a SETUP.md, not just --postgres --
      # even the base skeleton has a dev step (bin/server) and an
      # unscaffolded test framework to set up.
      write_setup_md!
    end

    private

    def write_live!
      LIVE_FILES.each { |relative, template| write_file(relative, template) }
      copy_live_client!
      add_live_to_layout!
    end

    # The runtime ships inside the gem (Monk::Live.client_dir); copied, not
    # duplicated under templates/, so there is one source of truth.
    def copy_live_client!
      source = File.join(__dir__, "live/client")
      target = File.join(@dir, LIVE_CLIENT_DIR)
      FileUtils.mkdir_p(target)
      FileUtils.cp(Dir.children(source).map { |name| File.join(source, name) }, target)
    end

    def add_live_to_layout!
      path = File.join(@dir, "views/layouts/app.erb")
      content = File.read(path)
      raise "layout wiring failed: </head> not found" unless content.include?("  </head>\n")

      File.write(path, content.sub("  </head>\n", "#{LIVE_HEAD}  </head>\n"))
    end

    def append_gemfile_extra(template_path)
      extra = File.read(File.join(TEMPLATES_DIR, template_path))
      File.write(File.join(@dir, "Gemfile"), "\n#{extra}", mode: "a")
    end

    # --postgres/--redis write a real .env (see write_env_files!) -- if the
    # dotenv gem stays commented out, as it does in the base skeleton,
    # config/settings.rb's `require "dotenv/load"` never runs, so nothing
    # ever actually loads them: bin/setup_db (or bin/websocket_server's
    # REDIS_URL check) silently falls back to config/persistence.rb's own
    # ENV.fetch defaults, or no REDIS_URL at all, instead of the
    # app-specific values .env was written to provide.
    DOTENV_COMMENTED_LINE = %(# gem "dotenv" # uncomment to load a local .env file (config/settings.rb)\n).freeze
    DOTENV_LINE = %(gem "dotenv" # loads .env/.env.test -- see config/settings.rb\n).freeze

    def uncomment_dotenv!
      path = File.join(@dir, "Gemfile")
      content = File.read(path)
      raise "Gemfile wiring failed: #{DOTENV_COMMENTED_LINE.inspect} not found" unless content.include?(DOTENV_COMMENTED_LINE)

      File.write(path, content.sub(DOTENV_COMMENTED_LINE, DOTENV_LINE))
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

      dev = @postgres ? pg_env_lines("#{app_name}_development") : []
      test = @postgres ? pg_env_lines("#{app_name}_test") : []
      example = @postgres ? pg_env_lines("#{app_name}_development") : []

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
      write_lines(".env.example", example)
      # --redis alone (no --postgres) has nothing to put in .env.test --
      # skip it rather than write an empty, pointless file.
      write_lines(".env.test", test) unless test.empty?
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
      File.write(File.join(@dir, "SETUP.md"), live_setup_md_content, mode: "a") if @live
    end

    def live_setup_md_content
      <<~MARKDOWN

        ## Live updates (Monk::Live)

        `monk new --live` wired a demo: a counter whose open tabs update by
        themselves. It needs three things running, each in its own terminal:

        ```bash
        docker run --rm -d -p 6379:6379 --name #{File.basename(@dir)}_redis redis:7   # skip if one is already up
        bin/server              # the HTTP app on :9292, which publishes updates
        bin/websocket_server    # the sockets on :9293, which deliver them
        ```

        Open http://localhost:9292 in two tabs and press the button in one.

        `bin/server` and `bin/websocket_server` are separate processes, so Redis
        (`REDIS_URL`, already in `.env`) is what carries an update from one to
        the other. Where things are:

        - `config/live.rb` -- the Redis wiring and the subscribe rules (nothing
          is allowed unless a rule says so).
        - `config.ru` -- `POST /hit` changes state and calls `Monk::Live.patch`.
        - `views/index.erb` -- `live_topic "hits"` marks what to subscribe to.
        - `views/live/_hits.erb` -- the fragment that gets pushed. Partials
          used this way see only their locals (`locals[:hits]`), never
          `params` or the session.
        - `public/js/monk_live/` -- the browser runtime, copied from the gem.
          The layout points at it and at `LIVE_WS_URL` (default
          `ws://localhost:9293`; use `wss://` in production).

        `WS_ALLOWED_ORIGINS` (default `http://localhost:9292`) must list the
        origin your pages are served from, or the browser's socket is refused.
      MARKDOWN
    end

    def setup_md_content
      @postgres ? postgres_setup_md_content : base_setup_md_content
    end

    # No Postgres, so no database/containers/migrations -- but still a
    # real dev-then-test walkthrough: bin/server needs nothing external,
    # and "no test framework scaffolded" is just as true here as it is
    # with --postgres.
    def base_setup_md_content
      app_name = File.basename(@dir)

      <<~MARKDOWN
        # Setting up #{app_name} (dev, then test)

        #{base_setup_md_intro(app_name)}

        ## Dev environment, first run

        ```bash
        bundle install
        bin/server              # HTTP app on :9292 -> http://localhost:9292/hello
        bin/websocket_server    # WS chat process on :9293, in another terminal
        ```
        #{redis_only_note}
        ## Test environment

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

        **test/test_helper.rb**:

        ```ruby
        $LOAD_PATH.unshift(File.expand_path("..", __dir__))

        ENV["MONK_ENV"] ||= "test"

        require "minitest/autorun"
        require_relative "../config/settings"
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

        **test/settings_test.rb** -- `config.ru`'s `class App` lives inline in a
        rackup file, not a plain `.rb` a test could `require_relative`, so this
        starts with what's actually requirable standalone. Extract `App` into
        its own file (`require_relative`d from both `config.ru` and
        `test/test_helper.rb`) once there's real app behavior worth testing
        against requests:

        ```ruby
        require_relative "test_helper"

        class SettingsTest < Minitest::Test
          def test_monk_env_reads_as_test
            assert_equal "test", Monk::Settings[:monk_env]
          end
        end
        ```

        Then:

        ```bash
        bundle install
        bundle exec rake test
        ```
      MARKDOWN
    end

    def base_setup_md_intro(app_name)
      unless @redis
        return "No external services are scaffolded here (`monk new #{app_name}`, no " \
          "`--postgres`/`--auth`/`--redis`) -- `bin/server`/`bin/websocket_server` need " \
          "nothing external to run."
      end

      "No database is scaffolded here (`monk new #{app_name} --redis`, no `--postgres`/" \
        "`--auth`) -- `bin/server` needs nothing external, but `bin/websocket_server`'s " \
        "cross-process fan-out needs a reachable Redis once `REDIS_URL` (already set in " \
        "the generated `.env`) is visible to it."
    end

    def redis_only_note
      return "" unless @redis

      app_name = File.basename(@dir)
      "\n`.env` already sets `REDIS_URL=redis://localhost:6379/0`, turning on " \
        "`bin/websocket_server`'s cross-process fan-out -- unset (or missing entirely), it " \
        "runs in-process only. Check `docker ps` first in case a Redis container is already " \
        "running from another project; otherwise start one: `docker run --rm -d -p 6379:6379 " \
        "--name #{app_name}_redis redis:7`.\n"
    end

    def postgres_setup_md_content
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
