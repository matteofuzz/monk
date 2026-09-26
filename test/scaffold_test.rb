require_relative "test_helper"
require "tmpdir"
require "monk/scaffold"

class ScaffoldTest < Minitest::Test
  def test_write_bang_creates_the_base_skeleton_matching_the_templates_exactly
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest).write!

      assert_equal template("base/Gemfile"), read(dest, "Gemfile")
      assert_equal template("base/config.ru"), read(dest, "config.ru")
      assert_equal template("base/config/settings.rb"), read(dest, "config/settings.rb")
      assert_equal template("base/.ruby-version"), read(dest, ".ruby-version")
      assert_equal template("base/.gitignore"), read(dest, ".gitignore")
      assert_equal template("base/.dockerignore"), read(dest, ".dockerignore")
      assert_equal template("base/Dockerfile"), read(dest, "Dockerfile")
      assert_equal template("base/bin/server"), read(dest, "bin/server")
      assert_equal template("base/bin/websocket_server"), read(dest, "bin/websocket_server")
      assert_equal template("base/views/layouts/app.erb"), read(dest, "views/layouts/app.erb")
      assert_equal template("base/views/index.erb"), read(dest, "views/index.erb")
      assert_equal template("base/public/css/app.css"), read(dest, "public/css/app.css")
      assert_equal template("base/public/js/app.js"), read(dest, "public/js/app.js")
    end
  end

  def test_write_bang_writes_bin_server_executable
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest).write!

      mode = File.stat(File.join(dest, "bin/server")).mode
      assert mode & 0o111 == 0o111, "expected bin/server to be executable"
    end
  end

  # bin/websocket_server ships in the base skeleton unconditionally --
  # WebSocket needs no external service, so unlike --postgres/--redis it
  # isn't gated behind a flag at all.
  def test_write_bang_writes_bin_websocket_server_executable
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest).write!

      mode = File.stat(File.join(dest, "bin/websocket_server")).mode
      assert mode & 0o111 == 0o111, "expected bin/websocket_server to be executable"
    end
  end

  # The generated app has to actually boot and serve its own page --
  # a scaffold whose templates don't compile is worse than none.
  def test_the_generated_app_boots_and_renders_its_index_page
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest).write!

      app = Class.new(Monk::Base) do
        get("/") { @title = "App"; render "index" }
      end
      app.views(File.join(dest, "views"))
      app.layout("layouts/app")
      app.assets(File.join(dest, "public"))
      Monk.boot(app)

      status, headers, body = app.call(env_for("GET", "/"))

      assert_equal 200, status
      assert_equal "text/html; charset=utf-8", headers["content-type"]
      assert_includes body.join, "<h1>It works</h1>"
      assert_includes body.join, %(<link rel="stylesheet" href="/css/app.css)

      css_status, css_headers, _css_body = app.call(env_for("GET", "/css/app.css"))

      assert_equal 200, css_status
      assert_equal "text/css; charset=utf-8", css_headers["content-type"]
    ensure
      Monk::Views.reset!
      Monk::Assets.reset!
    end
  end

  # config/settings.rb ships in the base skeleton regardless of
  # --postgres (MONK_ENV/dotenv apply either way), and config.ru requires
  # it before anything else -- this loads the actual generated file
  # (not a fresh Class.new(Monk::Base) app, unlike the boot test above),
  # proving it works standalone: a missing dotenv gem is a no-op, and
  # Monk::Settings' built-in :monk_env is readable afterward.
  def test_the_generated_config_settings_file_loads_standalone_without_dotenv_installed
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest).write!

      with_settings do
        load File.join(dest, "config/settings.rb")

        assert_kind_of String, Monk::Settings[:monk_env]
      end
    end
  end

  def test_write_bang_creates_missing_parent_directories
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "nested", "demo_app")

      Monk::Scaffold.new(dest).write!

      assert File.directory?(dest)
      assert File.exist?(File.join(dest, "Gemfile"))
    end
  end

  def test_write_bang_raises_a_precise_error_when_the_destination_already_exists
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Dir.mkdir(dest)

      error = assert_raises(Monk::ScaffoldExistsError) { Monk::Scaffold.new(dest).write! }

      assert_match(/demo_app/, error.message)
    end
  end

  def test_write_bang_with_postgres_adds_the_persistence_scaffold
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, postgres: true).write!

      assert_equal template("postgres/config/persistence.rb"), read(dest, "config/persistence.rb")
      assert_equal template("postgres/bin/console"), read(dest, "bin/console")
      assert_equal template("postgres/bin/setup_db"), read(dest, "bin/setup_db")
      assert_equal template("postgres/bin/migrate"), read(dest, "bin/migrate")
      assert File.directory?(File.join(dest, "db/migrate"))
      assert_empty Dir.children(File.join(dest, "db/migrate"))
    end
  end

  # Dockerfile ships unconditionally (base skeleton, like config.ru) --
  # --postgres overrides it with one that installs libpq for the pg gem's
  # native extension, the same override mechanism --live uses for config.ru.
  def test_write_bang_with_postgres_overrides_the_dockerfile_for_libpq
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, postgres: true).write!

      assert_equal template("postgres/Dockerfile"), read(dest, "Dockerfile")
      refute_equal template("base/Dockerfile"), read(dest, "Dockerfile")
    end
  end

  def test_write_bang_without_postgres_leaves_the_dockerfile_as_the_base_one
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest).write!

      assert_equal template("base/Dockerfile"), read(dest, "Dockerfile")
    end
  end

  # config.ru ships unconditionally (base skeleton), so --postgres can only
  # edit what's already there, not add/remove the file itself -- this is
  # what actually makes a scaffolded app boot with persistence registered,
  # instead of silently never loading config/persistence.rb at all.
  def test_write_bang_with_postgres_wires_config_ru_to_require_persistence
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, postgres: true).write!

      config_ru = read(dest, "config.ru")
      assert_includes config_ru, %(require_relative "config/settings"\nrequire_relative "config/persistence"\n)
      assert_includes config_ru, "class App < Monk::Base"
    end
  end

  # auth: true implies postgres: true, and config/auth.rb itself
  # require_relative "persistence" -- so config.ru only needs to reach
  # config/auth to pull in both.
  def test_write_bang_with_auth_wires_config_ru_to_require_auth_instead_of_persistence
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, auth: true).write!

      config_ru = read(dest, "config.ru")
      assert_includes config_ru, %(require_relative "config/settings"\nrequire_relative "config/auth"\n)
      refute_includes config_ru, %(require_relative "config/persistence")
    end
  end

  def test_write_bang_without_postgres_leaves_config_ru_untouched
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest).write!

      assert_equal template("base/config.ru"), read(dest, "config.ru")
    end
  end

  # .env/.env.test carry this project's own database name -- the one thing
  # in the whole scaffold that's genuinely per-app, unlike every other
  # template file (see the Scaffold class comment).
  def test_write_bang_with_postgres_writes_env_files_with_a_db_name_derived_from_the_directory
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, postgres: true).write!

      assert_includes read(dest, ".env"), "DB_NAME=demo_app_development"
      assert_includes read(dest, ".env.test"), "DB_NAME=demo_app_test"
      assert_includes read(dest, ".env.example"), "DB_NAME=demo_app_development"
      refute_includes read(dest, ".env"), "AUTH_SECRET"
      refute_includes read(dest, ".env"), "REDIS_URL"
    end
  end

  def test_write_bang_with_auth_adds_auth_secret_to_env_files_but_not_env_test_redis
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, auth: true).write!

      assert_includes read(dest, ".env"), "AUTH_SECRET="
      assert_includes read(dest, ".env.test"), "AUTH_SECRET="
      assert_includes read(dest, ".env.example"), "AUTH_SECRET="
    end
  end

  # REDIS_URL only matters to a test that actually exercises RedisFanout --
  # deliberately left out of .env.test, unlike DB_NAME/AUTH_SECRET which
  # every persistence/auth test needs.
  def test_write_bang_with_redis_adds_redis_url_to_env_but_not_env_test
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, postgres: true, redis: true).write!

      assert_includes read(dest, ".env"), "REDIS_URL="
      assert_includes read(dest, ".env.example"), "REDIS_URL="
      refute_includes read(dest, ".env.test"), "REDIS_URL"
    end
  end

  def test_write_bang_with_neither_postgres_nor_redis_writes_no_env_files
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest).write!

      refute File.exist?(File.join(dest, ".env"))
      refute File.exist?(File.join(dest, ".env.test"))
      refute File.exist?(File.join(dest, ".env.example"))
    end
  end

  def test_write_bang_with_postgres_writes_a_setup_md_naming_the_app_and_its_flags
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, auth: true, redis: true).write!

      setup_md = read(dest, "SETUP.md")
      assert_includes setup_md, "# Setting up demo_app"
      assert_includes setup_md, "bundle exec rake test" # the Minitest instructions the SETUP.md walks through
      assert_includes setup_md, "authenticate: true, redis fan-out: on"
      assert_includes setup_md, "demo_app_development"
      assert_includes setup_md, "demo_app_test"
    end
  end

  # Every flag combination gets a SETUP.md, not just --postgres -- even the
  # base skeleton has a dev step (bin/server) and an unscaffolded test
  # framework to set up.
  def test_write_bang_without_postgres_still_writes_a_setup_md
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest).write!

      setup_md = read(dest, "SETUP.md")
      assert_includes setup_md, "# Setting up demo_app"
      assert_includes setup_md, "bundle exec rake test"
      refute_includes setup_md, "createdb" # nothing Postgres-specific without --postgres
    end
  end

  # --redis alone (no --postgres) still gets a real .env with REDIS_URL,
  # and dotenv uncommented to actually load it -- otherwise
  # bin/websocket_server's REDIS_URL check silently never sees it, same
  # class of bug --postgres's own .env had before dotenv was wired up.
  def test_write_bang_with_redis_only_writes_env_files_and_uncomments_dotenv
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, redis: true).write!

      assert_includes read(dest, ".env"), "REDIS_URL="
      assert_includes read(dest, ".env.example"), "REDIS_URL="
      refute File.exist?(File.join(dest, ".env.test")) # nothing to put in it without --postgres
      refute_includes read(dest, ".env"), "DB_"

      gemfile = read(dest, "Gemfile")
      assert_match(/^gem "dotenv"/, gemfile)

      setup_md = read(dest, "SETUP.md")
      assert_includes setup_md, "REDIS_URL"
    end
  end

  def test_write_bang_with_postgres_writes_the_generated_scripts_executable
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, postgres: true).write!

      %w[bin/console bin/setup_db bin/migrate].each do |relative|
        mode = File.stat(File.join(dest, relative)).mode
        assert mode & 0o111 == 0o111, "expected #{relative} to be executable"
      end
    end
  end

  def test_write_bang_with_postgres_adds_pg_and_irb_on_top_of_the_base_gemfile
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "postgres_app")
      Monk::Scaffold.new(dest, postgres: true).write!

      gemfile = read(dest, "Gemfile")
      assert_includes gemfile, template("postgres/Gemfile.extra")
    end
  end

  # --postgres writes a real .env/.env.test (see write_env_files!) -- if
  # dotenv stayed commented out, as it does in the base skeleton,
  # config/settings.rb's `require "dotenv/load"` would never run, and
  # bin/setup_db would silently fall back to config/persistence.rb's own
  # ENV.fetch defaults instead of the app-specific values .env provides.
  def test_write_bang_with_postgres_uncomments_dotenv_in_the_gemfile
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, postgres: true).write!

      gemfile = read(dest, "Gemfile")
      assert_match(/^gem "dotenv"/, gemfile)
      refute_match(/^# gem "dotenv"/, gemfile)
    end
  end

  def test_write_bang_without_postgres_leaves_dotenv_commented_out
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest).write!

      assert_equal template("base/Gemfile"), read(dest, "Gemfile")
    end
  end

  def test_write_bang_with_auth_adds_the_auth_scaffold_on_top_of_postgres
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, auth: true).write!

      assert_equal template("auth/config/auth.rb"), read(dest, "config/auth.rb")
      assert_equal(
        template("auth/db/migrate/00000000000001_create_auth_tables.up.sql"),
        read(dest, "db/migrate/00000000000001_create_auth_tables.up.sql"),
      )
      assert_equal(
        template("auth/db/migrate/00000000000001_create_auth_tables.down.sql"),
        read(dest, "db/migrate/00000000000001_create_auth_tables.down.sql"),
      )
      # auth: true implies postgres: true -- Auth is Postgres-only
      assert_equal template("postgres/config/persistence.rb"), read(dest, "config/persistence.rb")
      assert File.exist?(File.join(dest, "bin/migrate"))
    end
  end

  # --mail on its own: Monk::Mail without Auth or Postgres.
  def test_write_bang_with_mail_adds_config_mail_and_net_smtp_only
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, mail: true).write!

      assert_equal template("mail/config/mail.rb"), read(dest, "config/mail.rb")
      assert_includes read(dest, "Gemfile"), template("mail/Gemfile.extra")
      refute File.exist?(File.join(dest, "views/mail/magic_link.erb"))
      refute File.exist?(File.join(dest, "config/auth.rb"))
      refute File.exist?(File.join(dest, "config/persistence.rb"))
      refute_includes read(dest, "Gemfile"), %(gem "pg")
    end
  end

  def test_write_bang_with_mail_wires_config_ru_right_after_settings
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, mail: true).write!

      assert_includes read(dest, "config.ru"), %(require_relative "config/settings"\nrequire_relative "config/mail"\n)
    end
  end

  # No Postgres, but MAIL_* are still worth an env file -- and without
  # dotenv uncommented, nothing would load it.
  def test_write_bang_with_mail_writes_env_files_and_uncomments_dotenv
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, mail: true).write!

      assert_includes read(dest, ".env"), "MAIL_FROM="
      refute_includes read(dest, ".env"), "DB_NAME"
      assert_includes read(dest, ".env.test"), "MAIL_URL=log://"
      assert_includes read(dest, ".env.example"), "MAIL_URL=smtp://"
      assert_includes read(dest, "Gemfile"), %(gem "dotenv" # loads)
    end
  end

  def test_write_bang_with_mail_mentions_mail_in_setup_md_without_auth
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, mail: true).write!

      setup_md = read(dest, "SETUP.md")
      assert_includes setup_md, "MAIL_URL"
      assert_includes setup_md, %(require_relative "../config/mail")
      refute_includes setup_md, "AppMailer"
      # Tests boot outside development, where an unset MAIL_URL raises --
      # so the test helper has to load .env.test (MAIL_URL=log://) before
      # config/mail.rb, as the --postgres variant already does for DB_NAME.
      dotenv_at = setup_md.index('Dotenv.load(File.expand_path(".env.test"')
      refute_nil dotenv_at, "expected the test helper to load .env.test"
      assert_operator dotenv_at, :<, setup_md.index('require_relative "../config/mail"')
    end
  end

  # --auth sends magic links, so it implies --mail, plus the HTML template
  # for the link.
  def test_write_bang_with_auth_adds_the_mail_scaffold
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, auth: true).write!

      assert_equal template("mail/config/mail.rb"), read(dest, "config/mail.rb")
      assert_equal template("auth/views/mail/magic_link.erb"), read(dest, "views/mail/magic_link.erb")
      assert_includes read(dest, "Gemfile"), template("mail/Gemfile.extra")
      assert_equal 1, read(dest, "Gemfile").scan("net-smtp").size
    end
  end

  def test_write_bang_with_auth_and_mail_writes_mail_once
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, auth: true, mail: true).write!

      assert_equal 1, read(dest, "Gemfile").scan("net-smtp").size
      assert_equal 1, read(dest, "config.ru").scan("config/mail").size
      assert_equal 1, read(dest, ".env.test").scan("MAIL_URL").size
    end
  end

  # config/mail.rb is required by config.ru only, not by config/auth.rb:
  # bin/websocket_server loads config/auth.rb as well, and never sends mail,
  # so it shouldn't need MAIL_URL set to boot.
  def test_write_bang_with_auth_wires_config_ru_to_require_mail_after_auth
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, auth: true).write!

      assert_includes read(dest, "config.ru"),
        %(require_relative "config/settings"\nrequire_relative "config/auth"\nrequire_relative "config/mail"\n)
      refute_includes read(dest, "config/auth.rb"), %(require_relative "mail")
    end
  end

  def test_write_bang_without_auth_scaffolds_no_mail
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, postgres: true).write!

      refute File.exist?(File.join(dest, "config/mail.rb"))
      refute_includes read(dest, "Gemfile"), "net-smtp"
      refute_includes read(dest, "config.ru"), "config/mail"
    end
  end

  # Unset MAIL_URL means log:// in development, so .env leaves it out; tests
  # boot outside development, where an unset one raises, so .env.test sets
  # log://; .env.example shows the production shape.
  def test_write_bang_with_auth_adds_mail_settings_to_env_files
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, auth: true).write!

      assert_includes read(dest, ".env"), "MAIL_FROM="
      refute_includes read(dest, ".env"), "MAIL_URL="
      assert_includes read(dest, ".env.test"), "MAIL_URL=log://"
      assert_includes read(dest, ".env.example"), "MAIL_URL=smtp://"
      assert_includes read(dest, ".env.example"), "MAIL_FROM="
    end
  end

  def test_write_bang_with_auth_mentions_mail_in_setup_md
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, auth: true).write!

      setup_md = read(dest, "SETUP.md")
      assert_includes setup_md, "MAIL_URL"
      assert_includes setup_md, %(require_relative "../config/mail")
    end
  end

  # The scaffolded pieces working together, as a generated app would load
  # them: settings, then mail, then auth (config.ru's order), views frozen,
  # then Monk::Auth's deliver: called from a worker Ractor under log://.
  def test_scaffolded_auth_delivers_the_magic_link_through_monk_mail
    require "monk/auth"
    require "monk/mail"

    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest, auth: true).write!

      log = with_log do |log_dir|
        with_settings do
          with_env("AUTH_SECRET", "s3cr3t") do
            with_env("MAIL_URL", "log://") do
              with_env("MAIL_FROM", "Demo <no-reply@demo.test>") do
                require File.join(dest, "config/settings")
                require File.join(dest, "config/mail")
                # config/auth.rb loads the scaffolded config/persistence.rb,
                # which registers :primary -- into a registry an earlier
                # test's boot may have left frozen.
                Monk::Persistence::Pg.reset! if defined?(Monk::Persistence::Pg)
                require File.join(dest, "config/auth")
                Monk::Views.reset!
                Monk::Views.root = File.join(dest, "views")
                # Only what the call below reads from a worker Ractor --
                # not Monk.freeze!, which would also seal the Pg registry
                # and Auth's models for every test that runs after this one.
                [Monk::Settings, Monk::Views, Monk::Log, Monk::Mail, Monk::Auth].each(&:freeze_registry!)

                Ractor.new do
                  Monk::Auth.config[:deliver].call(
                    email: "ann@example.test", link: "http://localhost:9292/auth/callback/abc", token: "abc",
                  )
                end.value
                File.read(File.join(log_dir, "test.log"))
              end
            end
          end
        end
      ensure
        Monk::Views.reset!
      end

      assert_includes log, %(to="ann@example.test")
      assert_includes log, %(from="Demo <no-reply@demo.test>")
      assert_includes log, "http://localhost:9292/auth/callback/abc"
      assert_match(/html=\d+ bytes/, log)
    end
  ensure
    Monk::Auth.reset!
    Monk::Mail.reset!
    Monk::Persistence::Pg.reset! if defined?(Monk::Persistence::Pg)
  end

  # redis: true is fully independent -- doesn't imply, and isn't implied
  # by, postgres or auth. There's no config/redis.rb, since there's
  # nothing to register a name against (REGISTRY is a plain module
  # constant in bin/websocket_server, and it reads REDIS_URL directly).
  def test_write_bang_with_redis_adds_the_redis_gem_and_no_persistence_files
    Dir.mktmpdir do |tmp|
      redis_dest = File.join(tmp, "redis_app")
      Monk::Scaffold.new(redis_dest, redis: true).write!

      assert_includes read(redis_dest, "Gemfile"), template("redis/Gemfile.extra")
      refute File.exist?(File.join(redis_dest, "config/persistence.rb"))
      refute File.exist?(File.join(redis_dest, "config/auth.rb"))
    end
  end

  private

  def template(relative)
    File.read(File.expand_path("../lib/monk/templates/#{relative}", __dir__))
  end

  def read(dest, relative)
    File.read(File.join(dest, relative))
  end
end
