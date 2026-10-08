require "fileutils"

require_relative "errors"

module Monk
  # Writes a new Monk project's skeleton to disk. Templates are static
  # files, copied verbatim -- nothing here needs the project's own name
  # substituted in, so there's no templating engine involved. See
  # docs/history/plan-init.md for the full design.
  class Scaffold
    TEMPLATES_DIR = File.expand_path("templates", __dir__)

    # The role directories under app/, in config/load.rb's load order.
    APP_ROLES = %w[models presenters helpers mailers broadcasts jobs].freeze

    BASE_FILES = {
      "Gemfile" => "base/Gemfile",
      "config.ru" => "base/config.ru",
      "config/settings.rb" => "base/config/settings.rb",
      "config/load.rb" => "base/config/load.rb",
      "app/app.rb" => "base/app/app.rb",
      ".ruby-version" => "base/.ruby-version",
      ".gitignore" => "base/.gitignore",
      ".dockerignore" => "base/.dockerignore",
      "Dockerfile" => "base/Dockerfile",
      "bin/server" => "base/bin/server",
      "bin/websocket_server" => "base/bin/websocket_server",
      "app/views/layouts/app.erb" => "base/app/views/layouts/app.erb",
      "app/views/index.erb" => "base/app/views/index.erb",
      # Every role directory, whatever the flags (docs/adr/0015): the tree
      # shows where each kind of code goes. Flags add files next to these.
      **APP_ROLES.to_h { |role| ["app/#{role}/.keep", "base/app/#{role}/.keep"] },
      "public/css/app.css" => "base/public/css/app.css",
      "public/js/app.js" => "base/public/js/app.js",
    }.freeze

    POSTGRES_FILES = {
      "config/persistence.rb" => "postgres/config/persistence.rb",
      "bin/console" => "postgres/bin/console",
      "bin/setup_db" => "postgres/bin/setup_db",
      "bin/migrate" => "postgres/bin/migrate",
      # Kept by git when empty, like app/'s role directories: a fresh clone
      # still shows where migrations go. The migrator reads only *.sql.
      "db/migrate/.keep" => "postgres/db/migrate/.keep",
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
      # The magic link's sender, Monk::Auth's deliver: hook -- config/auth.rb
      # requires it -- and the HTML part it renders and sends through
      # Monk::Mail (MAIL_FILES, implied by --auth).
      "app/mailers/app_mailer.rb" => "auth/app/mailers/app_mailer.rb",
      "app/views/mail/magic_link.erb" => "auth/app/views/mail/magic_link.erb",
    }.freeze

    # --mail, or implied by --auth: Monk::Mail's config. Its Gemfile line
    # (net-smtp) and MAIL_* env vars are added by #write! / #write_env_files!.
    MAIL_FILES = {
      "config/mail.rb" => "mail/config/mail.rb",
    }.freeze

    # --jobs: Monk::Jobs. The migration is the canonical one under
    # templates/jobs/db/migrate -- the same file Monk's own tests apply --
    # numbered after auth's so the two sort in order when both are present.
    JOBS_FILES = {
      "config/jobs.rb" => "jobs/config/jobs.rb",
      "app/jobs/hello_job.rb" => "jobs/app/jobs/hello_job.rb",
      "bin/jobs" => "jobs/bin/jobs",
      "db/migrate/00000000000002_create_jobs_tables.up.sql" => "jobs/db/migrate/00000000000002_create_jobs_tables.up.sql",
      "db/migrate/00000000000002_create_jobs_tables.down.sql" =>
        "jobs/db/migrate/00000000000002_create_jobs_tables.down.sql",
    }.freeze

    # --jobs's demo route, added right after this line in app/app.rb (the
    # base and the --live one both end their routes with it), so the
    # round trip -- enqueue from a request, run in bin/jobs -- works out of
    # the box.
    JOBS_ROUTE_ANCHOR = %(  get("/api/hello") { json(message: "hello from monk") }\n).freeze
    JOBS_ROUTE = <<~RUBY.gsub(/^(?!$)/, "  ").freeze

      # Enqueues the demo job (app/jobs/hello_job.rb) for bin/jobs to run:
      #   curl -X POST "http://localhost:9292/jobs/hello?name=Ann"
      post("/jobs/hello") { json(enqueued: HelloJob.enqueue(params[:name] || "world")) }
    RUBY

    # --live: Monk::Live's demo (a counter whose open tabs update when
    # another request changes it). These replace three base files outright
    # rather than patching them -- a live app and index are different
    # files, not one line of diff -- and add two. config.ru stays the base
    # one: config/load.rb is where --live's config gets wired in.
    LIVE_OVERRIDES = {
      "app/app.rb" => "live/app/app.rb",
      "bin/websocket_server" => "live/bin/websocket_server",
      "app/views/index.erb" => "live/app/views/index.erb",
    }.freeze

    # config/live.rb itself isn't here -- #write_live! picks between
    # LIVE_CONFIG_TEMPLATES[@live_transport] instead, since which one gets
    # written depends on --redis vs --postgres, not a fixed mapping.
    LIVE_FILES = {
      "app/views/live/_hits.erb" => "live/app/views/live/_hits.erb",
    }.freeze

    LIVE_CONFIG_TEMPLATES = {
      redis: "live/config/live.rb",
      postgres: "live/config/live_pg.rb",
    }.freeze

    # Where the client runtime lands in the app's public root (an app serves
    # it like any other static file; its files import each other by relative
    # path, so they stay together in one directory).
    LIVE_CLIENT_DIR = "public/js/monk_live".freeze

    LIVE_HEAD = <<~HTML.gsub(/^/, "    ").freeze
      <meta name="monk-live-url" content="<%= settings[:live_ws_url] %>">
      <script type="module" src="<%= asset_path "/js/monk_live/monk_live.js" %>"></script>
    HTML

    EXECUTABLE_FILES = %w[bin/server bin/websocket_server bin/console bin/setup_db bin/migrate bin/jobs].freeze

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
    # live: bin/server and bin/websocket_server are always separate
    # processes, so *something* has to carry a publish between them --
    # --redis (Monk::WebSocket::RedisFanout) or --postgres
    # (Monk::WebSocket::PgFanout, reusing --postgres's own DB_* settings,
    # no Redis to run). --live no longer silently defaults to one: with
    # neither flag, there's no way to tell whether this app has Postgres
    # available at all, so guessing would be as likely to hand back a
    # template that can't connect as one that can. --live --redis wins
    # over --postgres if both are passed (an explicit ask beats an
    # implied default); --live --postgres alone (or via --auth, which
    # implies --postgres) picks PgFanout; --live with neither raises.
    # See docs/design/live-pg-fanout.md / docs/history/plan-live-pg-fanout.md
    # for the design this decision comes from.
    #
    # mail: Monk::Mail on its own, no Postgres needed. auth: implies it, the
    # same way it implies postgres: a magic link has to reach someone.
    #
    # jobs: implies postgres, since the queue lives there, and nothing else.
    def initialize(dir, postgres: false, auth: false, redis: false, live: false, mail: false, jobs: false)
      @dir = dir
      # As passed, before anything is implied -- #summary reports the difference.
      @requested = { postgres: postgres, auth: auth, mail: mail, jobs: jobs, redis: redis, live: live }
      @auth = auth
      @jobs = jobs
      @postgres = postgres || auth || jobs
      @mail = mail || auth
      @live = live

      if @live
        @redis = redis || false
        @live_transport = if redis
          :redis
        elsif @postgres
          :postgres
        else
          raise Monk::AmbiguousLiveTransportError,
            "monk new --live needs --redis or --postgres to pick Monk::Live's cross-process " \
            "transport (bin/server and bin/websocket_server are always separate processes) -- " \
            "pass one explicitly, e.g. `--live --postgres` (docs/guides/live.md's " \
            "\"Without Redis\" section has the tradeoffs)"
        end
      else
        @redis = redis
      end
    end

    # The flags as resolved, for `monk new` to print: which flags were
    # given, which ones they implied and why, and which combinations change
    # what gets generated. The rule behind it, stated in `monk --help`: a
    # flag is implied when there's only one right answer (--auth can only
    # use Postgres), and required when there's a real choice (--live's
    # transport).
    def summary
      given = FLAG_ORDER.select { |flag| @requested[flag] }
      return ["Flags: none (the base skeleton)."] if given.empty?

      implied = implied_flags
      flags = given.map { |flag| "--#{flag}" }.join(" ")
      lines = implied.empty? ? ["Flags: #{flags}."] : ["Flags: #{flags}, which also turned on:"]
      implied.each do |flag, sources|
        lines << "  #{"--#{flag}".ljust(12)}(needed by #{sources.map { |source| "--#{source}" }.join(", ")})"
      end

      together = combinations
      lines << "Together they also generate:" unless together.empty?
      width = together.map { |pair, _| pair.length }.max
      lines.concat(together.map { |pair, what| "  #{pair.ljust(width)}  #{what}" })
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
        append_gemfile_extra("postgres/Gemfile.extra")
      end

      if @mail
        MAIL_FILES.each { |relative, template| write_file(relative, template) }
        append_gemfile_extra("mail/Gemfile.extra")
      end

      if @jobs
        JOBS_FILES.each { |relative, template| write_file(relative, template, executable: EXECUTABLE_FILES.include?(relative)) }
        add_jobs_route!
      end

      wire_load! if @postgres || @mail || @live
      append_gemfile_extra("redis/Gemfile.extra") if @redis

      # --postgres, --redis and --mail are the flags with anything worth
      # putting in an env file (a database, a REDIS_URL, MAIL_*) -- the
      # base skeleton alone has nothing to configure this way.
      if @postgres || @redis || @mail
        write_env_files!
        uncomment_dotenv!
      end

      AUTH_FILES.each { |relative, template| write_file(relative, template) } if @auth

      # Every combination of flags gets a SETUP.md, not just --postgres --
      # even the base skeleton has a dev step (bin/server) and an
      # unscaffolded test framework to set up.
      write_setup_md!
    end

    FLAG_ORDER = %i[postgres auth mail jobs redis live].freeze

    # Only these two imply anything, and only one flag each can need.
    IMPLIED_BY = { postgres: %i[auth jobs], mail: %i[auth] }.freeze

    private

    def implied_flags
      resolved = { postgres: @postgres, mail: @mail }
      IMPLIED_BY.filter_map do |flag, sources|
        next if @requested[flag] || !resolved[flag]

        [flag, sources.select { |source| @requested[source] }]
      end
    end

    def combinations
      pairs = []
      pairs << live_combination if @live
      pairs
    end

    def live_combination
      if @live_transport == :redis
        both = @postgres ? "; --redis wins over --postgres" : ""
        ["--live + --redis", "config/live.rb fans out over Redis (Monk::WebSocket::RedisFanout#{both})"]
      else
        ["--live + --postgres", "config/live.rb fans out over Postgres (Monk::WebSocket::PgFanout)"]
      end
    end

    def write_live!
      write_file("config/live.rb", LIVE_CONFIG_TEMPLATES.fetch(@live_transport))
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
      path = File.join(@dir, "app/views/layouts/app.erb")
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

    # config/load.rb ships in BASE_FILES unconditionally (config.ru and the
    # tests require it), so the flags can't gate whether it exists, only
    # which module configs it requires. Unlike BASE_FILES/POSTGRES_FILES/
    # AUTH_FILES, this is a post-write edit rather than a verbatim copy --
    # the alternative (a second, fuller load.rb template per flag
    # combination) would duplicate the whole file for a few lines of diff.
    def wire_load!
      path = File.join(@dir, "config/load.rb")
      settings_require = %(require_relative "settings"\n)
      requires = +""
      if @postgres
        target = @auth ? "auth" : "persistence" # config/auth.rb itself require_relative "persistence"
        requires << "require_relative \"#{target}\"\n"
      end
      # config/mail.rb from config/load.rb only, never from config/auth.rb:
      # bin/websocket_server loads config/auth.rb too and never sends mail,
      # so it shouldn't need MAIL_URL to boot.
      requires << "require_relative \"mail\"\n" if @mail
      requires << "require_relative \"jobs\"\n" if @jobs
      requires << "require_relative \"live\"\n" if @live

      content = File.read(path)
      raise "config/load.rb wiring failed: #{settings_require.inspect} not found" unless content.include?(settings_require)

      File.write(path, content.sub(settings_require, "#{settings_require}#{requires}"))
    end

    def add_jobs_route!
      path = File.join(@dir, "app/app.rb")
      content = File.read(path)
      raise "app/app.rb wiring failed: #{JOBS_ROUTE_ANCHOR.inspect} not found" unless content.include?(JOBS_ROUTE_ANCHOR)

      File.write(path, content.sub(JOBS_ROUTE_ANCHOR, "#{JOBS_ROUTE_ANCHOR}#{JOBS_ROUTE}"))
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

      if @mail
        # MAIL_URL is left out of .env on purpose: unset in development
        # means log://, the message printed to the console. Tests boot
        # outside development, where an unset one raises, hence log:// there.
        dev << %(MAIL_FROM="#{app_name} <no-reply@localhost>")
        test << "MAIL_URL=log://"
        test << %(MAIL_FROM="#{app_name} <no-reply@localhost>")
        example << "MAIL_URL=smtp://user:password@smtp.example.com:587"
        example << %(MAIL_FROM="#{app_name} <no-reply@example.com>")
      end

      # bin/jobs's settings. Not in .env.test: tests run jobs with
      # Monk::Jobs.drain!, never a job process. The mailers queue is served
      # first, so a backlog of other work never delays a login email
      # (docs/adr/0014) -- with or without mail, since an empty queue costs
      # nothing (docs/adr/0017).
      if @jobs
        [dev, example].each { |lines| lines.push("JOBS_WORKERS=2", "JOBS_QUEUES=mailers,default") }
      end

      # REDIS_URL is absent from .env.test for --redis alone -- only a test
      # that actually exercises RedisFanout needs it. --live --redis is
      # different: config/live.rb raises without it, and the test helper
      # loads config/live.rb through config/load.rb. Building the fanout
      # connects to nothing, so tests still need no Redis running unless
      # one publishes.
      if @redis
        dev << "REDIS_URL=redis://localhost:6379/0"
        example << "REDIS_URL=redis://localhost:6379/0"
        test << "REDIS_URL=redis://localhost:6379/0" if live_over_redis?
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
      @live_transport == :postgres ? live_setup_md_content_postgres : live_setup_md_content_redis
    end

    def live_setup_md_content_redis
      <<~MARKDOWN

        ## Live updates (Monk::Live)

        `monk new --live --redis` wired a demo: a counter whose open tabs
        update by themselves. It needs three things running, each in its own
        terminal:

        ```bash
        docker run --rm -d -p 6379:6379 --name #{File.basename(@dir)}_redis redis:7   # skip if one is already up
        bin/server              # the HTTP app on :9292, which publishes updates
        bin/websocket_server    # the sockets on :9293, which deliver them
        ```

        Open http://localhost:9292 in two tabs and press the button in one.

        `bin/server` and `bin/websocket_server` are separate processes, so Redis
        (`REDIS_URL`, already in `.env`) is what carries an update from one to
        the other. Where things are:

        - `config/live.rb` -- the Redis wiring (`Monk::WebSocket::RedisFanout`)
          and the subscribe rules (nothing is allowed unless a rule says so).
        - `app/app.rb` -- `POST /hit` changes state and calls `Monk::Live.patch`.
        - `app/views/index.erb` -- `live_topic "hits"` marks what to subscribe to.
        - `app/views/live/_hits.erb` -- the fragment that gets pushed. Partials
          used this way see only their locals (`locals[:hits]`), never
          `params` or the session.
        - `bin/websocket_server` -- calls `Monk::Live.listen!` at boot: the
          only process that listens for updates. `bin/server`#{@jobs ? " and `bin/jobs`" : ""} only
          publish.
        - `public/js/monk_live/` -- the browser runtime, copied from the gem.
          The layout points at it and at `LIVE_WS_URL` (default
          `ws://localhost:9293`; use `wss://` in production).

        `WS_ALLOWED_ORIGINS` (default `http://localhost:9292`) must list the
        origin your pages are served from, or the browser's socket is refused.
        #{live_auth_setup_paragraph}
      MARKDOWN
    end

    def live_setup_md_content_postgres
      <<~MARKDOWN

        ## Live updates (Monk::Live)

        `monk new --live --postgres` wired a demo: a counter whose open tabs
        update by themselves. It needs two things running, each in its own
        terminal -- no Redis, since Postgres `LISTEN`/`NOTIFY` carries the
        update instead:

        ```bash
        bin/server              # the HTTP app on :9292, which publishes updates
        bin/websocket_server    # the sockets on :9293, which deliver them
        ```

        Open http://localhost:9292 in two tabs and press the button in one.

        `bin/server` and `bin/websocket_server` are separate processes, so
        Postgres `LISTEN`/`NOTIFY` (the same `DB_*` settings already in `.env`)
        is what carries an update from one to the other. Where things are:

        - `config/live.rb` -- the Postgres wiring (`Monk::WebSocket::PgFanout`)
          and the subscribe rules (nothing is allowed unless a rule says so).
        - `app/app.rb` -- `POST /hit` changes state and calls `Monk::Live.patch`.
        - `app/views/index.erb` -- `live_topic "hits"` marks what to subscribe to.
        - `app/views/live/_hits.erb` -- the fragment that gets pushed. Partials
          used this way see only their locals (`locals[:hits]`), never
          `params` or the session.
        - `bin/websocket_server` -- calls `Monk::Live.listen!` at boot: the
          only process that listens for updates. `bin/server`#{@jobs ? " and `bin/jobs`" : ""} only
          publish.
        - `public/js/monk_live/` -- the browser runtime, copied from the gem.
          The layout points at it and at `LIVE_WS_URL` (default
          `ws://localhost:9293`; use `wss://` in production).

        `WS_ALLOWED_ORIGINS` (default `http://localhost:9292`) must list the
        origin your pages are served from, or the browser's socket is refused.
        #{live_auth_setup_paragraph}
        A single broadcast is capped at just under 8000 bytes
        (`Monk::WebSocket::PgFanout::MAX_NOTIFY_PAYLOAD_BYTES`, Postgres's own
        `NOTIFY` limit) -- far more than this demo ever sends, but worth
        knowing before pushing much larger partials this way. Regenerate with
        `--redis` instead of `--postgres` if that becomes a real constraint.
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
        #{redis_only_note}#{mail_setup_note}
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
        #{base_test_dotenv_lines}
        #{test_helper_app_lines}
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

        #{app_test_sample}

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

        `config/load.rb`, `.env`, and `.env.test` are already wired up by `monk new`
        -- `config/load.rb` requires `config/#{@auth ? "auth" : "persistence"}` (and every other config
        you enabled), then loads `app/`, and
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
        #{"bin/jobs                # background jobs (app/jobs/), in a third terminal\n" if @jobs}```
        #{auth_or_redis_confirmation_note}#{mail_setup_note}#{jobs_setup_note}
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
        loads and boots the app the same way `config.ru` does:

        ```ruby
        $LOAD_PATH.unshift(File.expand_path("..", __dir__))

        ENV["MONK_ENV"] ||= "test"

        require "dotenv"
        Dotenv.load(File.expand_path(".env.test", __dir__ + "/.."))

        #{test_helper_app_lines}
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

        #{app_test_sample}
        #{jobs_test_sample}
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
      return live_auth_confirmation_note if @live
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

    # Who gets which topics once there are users. Interpolated into a
    # squiggly heredoc, so no indentation of its own.
    def live_auth_setup_paragraph
      return "" unless @auth

      <<~MARKDOWN

        **Visitors and logged-in users.** A logged-in user's socket carries
        their identity (the session cookie reaches `:9293` too); a visitor's
        comes in anonymous. Each topic's rule in `config/live.rb` decides:
        `anonymous: true` opens it to visitors (the demo's `hits`), and a
        rule without it is for logged-in users only, e.g. one topic per user.
        `monk new` writes no login routes: see `docs/guides/auth.md` in the
        monk repo, and `docs/guides/live.md`, "Who may subscribe".
      MARKDOWN
    end

    # The --live bin/websocket_server prints only `authenticate:`, and with
    # --auth it's :optional (a visitor's socket is anonymous, not refused).
    def live_auth_confirmation_note
      return "" unless @auth

      "\n`bin/websocket_server`'s startup line should print `authenticate: optional` once " \
        "`AUTH_SECRET` is visible to it: a logged-in user's socket carries their identity, and a " \
        "visitor's comes in anonymous, so it gets only the topics `config/live.rb` opens with " \
        "`anonymous: true`.\n"
    end

    # Interpolated into a squiggly heredoc, so no leading indentation of
    # its own (interpolated text isn't dedented).
    def mail_setup_note
      return "" unless @mail

      <<~MARKDOWN

        ### Email

        `config/mail.rb` configures `Monk::Mail`; send with
        `Monk::Mail.deliver(to:, subject:, text:, html:)`.#{auth_mail_sentence} In
        development `MAIL_URL` is unset, so messages are printed to the
        console instead of sent. Outside
        development set `MAIL_URL` (e.g. `smtp://user:pass@smtp.provider.com:587`)
        and `MAIL_FROM` to a sender on a domain you've verified with your
        provider -- an unset `MAIL_URL` fails the boot there. Provider
        examples: `docs/guides/mail.md` in the monk repo.
      MARKDOWN
    end

    # Interpolated into a squiggly heredoc, so no indentation of its own.
    def jobs_setup_note
      return "" unless @jobs

      <<~MARKDOWN

        ### Background jobs

        `config/jobs.rb` configures `Monk::Jobs` on the app's own database --
        its tables come from `db/migrate/00000000000002_create_jobs_tables`,
        which `bin/setup_db` already applied. The job classes live in
        `app/jobs/`, which `config/load.rb` loads. With `bin/server` and
        `bin/jobs` both running, enqueue the demo job and watch it run:

        ```bash
        curl -X POST "http://localhost:9292/jobs/hello?name=Ann"
        tail -f log/development.log   # ... INFO Hello, Ann, from a background job
        ```

        `JOBS_WORKERS` and `JOBS_QUEUES` (in `.env`) set how many worker Ractors
        `bin/jobs` runs and which queues they take jobs from, in order. A job
        may run more than once (its process was killed mid-job, say), so make
        each one safe to repeat. `TERM` or Ctrl-C lets the jobs in hand finish
        before `bin/jobs` exits.#{jobs_mail_note}#{jobs_auth_note}
      MARKDOWN
    end

    # Interpolated into a squiggly heredoc, so no indentation of its own.
    def jobs_mail_note
      return "" unless @mail

      <<~MARKDOWN.chomp

        To send an email from a job instead of the request, use
        `Monk::Mail.deliver_later` -- the same arguments as `deliver` (render
        HTML first with `Monk::Mail.render`), plus `wait:`/`at:`, or `conn:`
        to enqueue inside your own transaction. It goes on the `mailers`
        queue, which `JOBS_QUEUES` serves first. Temporary failures are
        retried; a refusal the mail server made final is not.
      MARKDOWN
    end

    # Interpolated into a squiggly heredoc, so no indentation of its own.
    def jobs_auth_note
      return "" unless @auth

      <<~MARKDOWN.chomp

        Magic links can go through a job too: `Monk::Auth::SendLoginLink`,
        which ships with Monk, creates the token and sends the link inside
        the job, so the raw token is never stored, not even in the queue.
        Your login route, after its own per-email rate limit, just enqueues
        it:

        ```ruby
        post("/auth/request") do
          Monk::Auth::SendLoginLink.enqueue(params[:email])
          json(sent: true)
        end
        ```

        Don't point `config/auth.rb`'s `deliver:` at `deliver_later`: that
        would store the link, token included, in the queue until it's sent.
      MARKDOWN
    end

    # Interpolated into a squiggly heredoc, so no indentation of its own.
    def jobs_test_sample
      return "" unless @jobs

      <<~MARKDOWN

        **test/jobs_test.rb** -- `Monk::Jobs.drain!` runs every enqueued job
        right in the test (each in its own Ractor, as `bin/jobs` would, so a
        job that only works outside one fails here too), and
        `Monk::Jobs.clear!` empties the queue between tests:

        ```ruby
        require_relative "test_helper"

        class JobsTest < Minitest::Test
          def teardown
            Monk::Jobs.clear!
          end

          def test_the_demo_job_runs
            HelloJob.enqueue("test")

            assert_equal 1, Monk::Jobs.drain!
          end
        end
        ```
      MARKDOWN
    end

    # The no-Postgres test helper normally has nothing to load from
    # .env.test -- but with --mail it has MAIL_URL=log://, which tests need
    # (they boot outside development, where an unset MAIL_URL raises), and
    # with --live --redis it has REDIS_URL, which config/live.rb needs.
    # Interpolated into a squiggly heredoc, so no indentation of its own.
    def base_test_dotenv_lines
      return "" unless @mail || live_over_redis?

      %(\nrequire "dotenv"\nDotenv.load(File.expand_path(".env.test", __dir__ + "/.."))\n)
    end

    def auth_mail_sentence
      return "" unless @auth

      " `AppMailer::MAGIC_LINK` (`app/mailers/app_mailer.rb`) sends each login link through it " \
        "(HTML part: `app/views/mail/magic_link.erb`)."
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
              assert_equal 1, conn.exec("SELECT 1").getvalue(0, 0)
            end
          end
        RUBY
      end
    end

    def live_over_redis? = @live && @live_transport == :redis

    # The end of every SETUP.md test helper: the app loaded the way
    # config.ru loads it (config/load.rb, then app/app.rb), booted once.
    # Interpolated into a squiggly heredoc, so no indentation of its own.
    def test_helper_app_lines
      <<~RUBY.chomp
        require "minitest/autorun"
        require_relative "../config/load"
        require_relative "../app/app"

        # Booted once, as config.ru does: request tests call APP.
        APP = Monk.boot(App)
      RUBY
    end

    # A request through the booted app. Every generated app, --live's
    # included, has GET /hello.
    def app_test_sample
      <<~MARKDOWN.chomp
        **test/app_test.rb** -- a request through the booted app:

        ```ruby
        require_relative "test_helper"
        require "rack/mock_request"

        class AppTest < Minitest::Test
          def test_hello
            status, _headers, body = APP.call(Rack::MockRequest.env_for("/hello"))

            assert_equal 200, status
            assert_equal "hello from monk", body.join
          end
        end
        ```
      MARKDOWN
    end

    def write_file(relative_path, template_path, executable: false)
      destination = File.join(@dir, relative_path)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(File.join(TEMPLATES_DIR, template_path), destination)
      File.chmod(0o755, destination) if executable
    end
  end
end
