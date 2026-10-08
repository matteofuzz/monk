require_relative "test_helper"
require "tmpdir"
require "open3"
require "monk/scaffold"
require "monk/persistence/pg"

class ScaffoldTest < Minitest::Test
  include PersistenceTestHelpers

  def test_write_bang_creates_the_base_skeleton_matching_the_templates_exactly
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest).write!

      assert_equal template("base/Gemfile"), read(dest, "Gemfile")
      assert_equal template("base/config.ru"), read(dest, "config.ru")
      assert_equal template("base/config/settings.rb"), read(dest, "config/settings.rb")
      assert_equal template("base/config/load.rb"), read(dest, "config/load.rb")
      assert_equal template("base/app/app.rb"), read(dest, "app/app.rb")
      assert_equal template("base/.ruby-version"), read(dest, ".ruby-version")
      assert_equal template("base/.gitignore"), read(dest, ".gitignore")
      assert_equal template("base/.dockerignore"), read(dest, ".dockerignore")
      assert_equal template("base/Dockerfile"), read(dest, "Dockerfile")
      assert_equal template("base/bin/server"), read(dest, "bin/server")
      assert_equal template("base/bin/websocket_server"), read(dest, "bin/websocket_server")
      assert_equal template("base/app/views/layouts/app.erb"), read(dest, "app/views/layouts/app.erb")
      assert_equal template("base/app/views/index.erb"), read(dest, "app/views/index.erb")
      assert_equal template("base/public/css/app.css"), read(dest, "public/css/app.css")
      assert_equal template("base/public/js/app.js"), read(dest, "public/js/app.js")
      assert_equal template("base/Rakefile"), read(dest, "Rakefile")
      assert_equal template("base/test/test_helper.rb"), read(dest, "test/test_helper.rb")
      assert_equal template("base/test/app_test.rb"), read(dest, "test/app_test.rb")
    end
  end

  # The base app ships its test setup (docs/adr/0017), and the generated
  # app's own suite passes as written -- run here in a fresh Ruby, the way
  # `bundle exec rake test` runs it, on Monk's bundle instead of the app's
  # (whose Gemfile would fetch monkrb from rubygems.org). The mail app's
  # helper has to load .env.test (MAIL_URL=log://, or booting outside
  # development raises); the live app's config/live.rb needs REDIS_URL.
  def test_the_generated_apps_own_tests_pass
    [{}, { mail: true }, { live: true, redis: true }].each do |flags|
      Dir.mktmpdir do |tmp|
        dest = File.join(tmp, "demo_app")
        Monk::Scaffold.new(dest, **flags).write!

        out, status = run_generated_tests(dest)

        assert status.success?, "#{flags.inspect}:\n#{out}"
        assert_match(/\d+ runs, \d+ assertions, 0 failures, 0 errors/, out, flags.inspect)
      end
    end
  end

  # Every role directory ships, whatever the flags, each with a .keep so
  # git keeps it while it's empty -- and in the order config/load.rb loads
  # them, so the two lists can't drift apart.
  def test_write_bang_creates_every_app_role_directory
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest).write!

      %w[models presenters helpers mailers broadcasts jobs].each do |role|
        assert File.exist?(File.join(dest, "app/#{role}/.keep")), "expected app/#{role}/.keep"
      end
      assert_includes read(dest, "config/load.rb"), "%w[#{Monk::Scaffold::APP_ROLES.join(" ")}]"
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
  # a scaffold whose templates don't compile is worse than none. Loads
  # the generated config/load.rb and app/app.rb the way config.ru does,
  # from the app's root (views/assets are relative to it, as under
  # bin/server). with_generated_app_class removes the top-level App
  # afterwards, so it doesn't leak into other tests.
  def test_the_generated_app_boots_and_renders_its_index_page
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest).write!

      with_settings do
        Dir.chdir(dest) do
          require File.join(dest, "config/load")
          with_generated_app_class(dest) do |app|
            Monk.boot(app)

            status, headers, body = app.call(env_for("GET", "/"))

            assert_equal 200, status
            assert_equal "text/html; charset=utf-8", headers["content-type"]
            assert_includes body.join, "<h1>It works</h1>"
            assert_includes body.join, %(<link rel="stylesheet" href="/css/app.css)

            css_status, css_headers, _css_body = app.call(env_for("GET", "/css/app.css"))

            assert_equal 200, css_status
            assert_equal "text/css; charset=utf-8", css_headers["content-type"]
          end
        end
      end
    ensure
      Monk::Views.reset!
      Monk::Assets.reset!
    end
  end

  # config/settings.rb ships in the base skeleton regardless of
  # --postgres (MONK_ENV/dotenv apply either way), and config/load.rb
  # requires it before anything else -- this loads the generated file on
  # its own, proving it works standalone: a missing dotenv gem is a no-op,
  # and Monk::Settings' built-in :monk_env is readable afterward.
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
      # A .keep, as app/'s role directories have: git doesn't keep an empty
      # directory, so a fresh clone would have no db/migrate at all.
      assert_equal [".keep"], Dir.children(File.join(dest, "db/migrate"))
    end
  end

  # pg 1.6+ ships precompiled Linux gems with libpq bundled (checked with a
  # real ruby:4.0-slim build, docs/plan-scaffold.md decision 21), so the
  # base Dockerfile, with no system packages, serves every app: no flag
  # replaces it.
  def test_the_dockerfile_is_the_base_one_whatever_the_flags
    [{}, { postgres: true }, { auth: true, jobs: true }].each do |flags|
      Dir.mktmpdir do |tmp|
        dest = File.join(tmp, "demo_app")

        Monk::Scaffold.new(dest, **flags).write!

        assert_equal template("base/Dockerfile"), read(dest, "Dockerfile"), flags.inspect
      end
    end
  end

  def test_postgres_asks_for_a_pg_with_precompiled_linux_gems
    assert_includes template("postgres/Gemfile.extra"), %(gem "pg", "~> 1.6")
  end

  # app/app.rb loads every file under app/routes/, each reopening class App,
  # so a module's routes (monk add) never edit app/app.rb (docs/adr/0017).
  def test_routes_in_app_routes_are_served_next_to_app_rb
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest).write!
      assert File.exist?(File.join(dest, "app/routes/.keep"))
      write_file(dest, "app/routes/extra.rb", %(class App\n  get("/extra") { "extra route" }\nend\n))

      with_settings do
        Dir.chdir(dest) do
          require File.join(dest, "config/load")
          with_generated_app_class(dest) do |app|
            Monk.boot(app)

            assert_equal "extra route", app.call(env_for("GET", "/extra"))[2].join
            assert_equal 200, app.call(env_for("GET", "/hello"))[0]
          end
        end
      end
    ensure
      Monk::Views.reset!
      Monk::Assets.reset!
    end
  end

  # config/load.rb is static (docs/adr/0017): it requires whichever module
  # configs exist, so no flag ever edits it.
  def test_config_load_is_the_base_template_whatever_the_flags
    [{}, { postgres: true }, { auth: true }, { mail: true }, { jobs: true, auth: true },
     { live: true, redis: true },].each do |flags|
      Dir.mktmpdir do |tmp|
        dest = File.join(tmp, "demo_app")

        Monk::Scaffold.new(dest, **flags).write!

        assert_equal template("base/config/load.rb"), read(dest, "config/load.rb"), flags.inspect
      end
    end
  end

  # The template itself, run in a fresh Ruby with stub configs that print
  # their name: only the configs that exist load, in Monk's fixed order,
  # whatever order they were added in.
  def test_config_load_requires_the_module_configs_that_exist_in_monks_order
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      FileUtils.cp(File.join(Monk::Scaffold::TEMPLATES_DIR, "base/config/load.rb"), File.join(dir, "config/load.rb"))
      write_file(dir, "config/settings.rb", %(print "settings "\n))
      %w[live jobs mail persistence].each { |name| write_file(dir, "config/#{name}.rb", %(print "#{name} "\n)) }

      out, err, status = Open3.capture3(RbConfig.ruby, "-e", %(require "./config/load"), chdir: dir)

      assert status.success?, err
      assert_equal "settings persistence mail jobs live ", out
    end
  end

  # Every flag is wired in config/load.rb, so config.ru is the same three
  # lines whatever monk new was given.
  def test_config_ru_is_the_base_one_for_every_flag
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, auth: true, jobs: true, live: true, redis: true).write!

      assert_equal template("base/config.ru"), read(dest, "config.ru")
    end
  end

  # config/load.rb loads each role directory under app/ that exists, in
  # role order, and skips the ones an app hasn't created.
  def test_the_generated_config_load_loads_app_code_by_role_in_order
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest).write!
      %w[broadcasts helpers presenters models].each do |role|
        FileUtils.mkdir_p(File.join(dest, "app/#{role}"))
        File.write(File.join(dest, "app/#{role}/probe.rb"), "$monk_load_order << #{role.inspect}\n")
      end

      $monk_load_order = []
      with_settings { require File.join(dest, "config/load") }

      assert_equal %w[models presenters helpers broadcasts], $monk_load_order
    ensure
      $monk_load_order = nil
    end
  end

  # An app's own helper: a module in app/helpers/ that includes itself into
  # Monk::Context, so every template can call it bare -- loaded by
  # config/load.rb before Boot, like Monk::Auth's and Monk::Live's. The
  # include is global and can't be undone, hence the one-off names.
  def test_a_helper_in_app_helpers_is_callable_from_the_generated_apps_templates
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest).write!
      FileUtils.mkdir_p(File.join(dest, "app/helpers"))
      File.write(File.join(dest, "app/helpers/scaffold_probe_helpers.rb"), <<~RUBY)
        module ScaffoldProbeHelpers
          def scaffold_probe_greeting = "hello from app/helpers"
        end

        Monk::Context.include(ScaffoldProbeHelpers)
      RUBY
      File.write(File.join(dest, "app/views/index.erb"), "<p><%= scaffold_probe_greeting %></p>\n")

      with_settings do
        Dir.chdir(dest) do
          require File.join(dest, "config/load")
          with_generated_app_class(dest) do |app|
            Monk.boot(app)

            _status, _headers, body = app.call(env_for("GET", "/"))

            assert_includes body.join, "<p>hello from app/helpers</p>"
          end
        end
      end
    ensure
      Monk::Views.reset!
      Monk::Assets.reset!
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

  # The sample test SETUP.md hands a --postgres app, run as the app would
  # run it, against a real database: it has to pass as written, including
  # how Monk's connections decode the value it checks.
  def test_setup_mds_sample_postgres_test_passes_as_written
    skip_unless_postgres_available

    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest, postgres: true).write!
      sample = read(dest, "SETUP.md")[%r{\*\*test/persistence_test\.rb\*\*.*?```ruby\n(.*?)```}m, 1]
      sample = sample.sub(%(require_relative "test_helper"\n), "")
      sample = sample.sub("class PersistenceTest < Minitest::Test", "Class.new(Minitest::Test) do")

      Monk::Persistence::Pg.reset!
      Monk::Persistence::Pg.register(:primary, **pg_test_opts)
      sample_test = eval(sample) # rubocop:disable Security/Eval
      result = sample_test.new("test_connects_to_the_test_database").run

      assert_predicate result, :passed?, result.failures.map(&:message).join("\n")
    ensure
      Monk::Persistence::Pg.reset! if defined?(Monk::Persistence::Pg)
    end
  end

  # Every flag combination gets a SETUP.md, not just --postgres -- even the
  # base skeleton has a dev step (bin/server) and its tests to run.
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
  # which the base Gemfile's dotenv loads.
  def test_write_bang_with_redis_only_writes_env_files
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

  # dotenv is in every app's Gemfile (docs/adr/0017): modules add .env lines,
  # and config/settings.rb's `require "dotenv/load"` must find the gem, or
  # bin/setup_db would silently fall back to config/persistence.rb's own
  # ENV.fetch defaults instead of the app-specific values .env provides.
  # Flags only append to the Gemfile, never edit its base lines.
  def test_every_gemfile_loads_dotenv_and_starts_with_the_base_one
    assert_match(/^gem "dotenv"/, template("base/Gemfile"))

    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, postgres: true, mail: true, redis: true).write!

      assert read(dest, "Gemfile").start_with?(template("base/Gemfile"))
    end
  end

  def test_write_bang_without_flags_writes_the_base_gemfile
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

  # The test setup ships as files, so SETUP.md says how to run it and no
  # longer how to write it, whatever the flags.
  def test_setup_md_runs_the_shipped_tests_instead_of_explaining_how_to_set_them_up
    [{}, { mail: true }, { postgres: true }, { auth: true, jobs: true }, { live: true, redis: true }].each do |flags|
      Dir.mktmpdir do |tmp|
        dest = File.join(tmp, "demo_app")
        Monk::Scaffold.new(dest, **flags).write!

        setup_md = read(dest, "SETUP.md")
        assert_includes setup_md, "bundle exec rake test", "flags: #{flags}"
        refute_includes setup_md, "**test/test_helper.rb**", "flags: #{flags}"
        refute_includes setup_md, "**Rakefile**", "flags: #{flags}"
        refute_includes setup_md, %(gem "minitest"), "flags: #{flags}"
      end
    end
  end

  # --live --redis's config/live.rb raises without REDIS_URL, and the test
  # helper loads it through config/load.rb -- so .env.test carries it.
  # Building the fanout connects to nothing, so tests need no Redis running
  # unless one publishes. --redis alone still leaves it out (below).
  def test_live_with_redis_puts_redis_url_in_env_test
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, live: true, redis: true).write!

      assert_includes read(dest, ".env.test"), "REDIS_URL=redis://localhost:6379/0"
    end
  end

  # --mail on its own: Monk::Mail without Auth or Postgres.
  def test_write_bang_with_mail_adds_config_mail_and_net_smtp_only
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, mail: true).write!

      assert_equal template("mail/config/mail.rb"), read(dest, "config/mail.rb")
      assert_includes read(dest, "Gemfile"), template("mail/Gemfile.extra")
      refute File.exist?(File.join(dest, "app/views/mail/magic_link.erb"))
      refute File.exist?(File.join(dest, "config/auth.rb"))
      refute File.exist?(File.join(dest, "config/persistence.rb"))
      refute_includes read(dest, "Gemfile"), %(gem "pg")
    end
  end

  # No Postgres, but MAIL_* are still worth an env file.
  def test_write_bang_with_mail_writes_env_files
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, mail: true).write!

      assert_includes read(dest, ".env"), "MAIL_FROM="
      refute_includes read(dest, ".env"), "DB_NAME"
      assert_includes read(dest, ".env.test"), "MAIL_URL=log://"
      assert_includes read(dest, ".env.example"), "MAIL_URL=smtp://"
    end
  end

  def test_write_bang_with_mail_mentions_mail_in_setup_md_without_auth
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, mail: true).write!

      setup_md = read(dest, "SETUP.md")
      assert_includes setup_md, "MAIL_URL"
      refute_includes setup_md, "AppMailer"
      # Tests boot outside development, where an unset MAIL_URL raises --
      # so the shipped test helper loads .env.test (MAIL_URL=log://) before
      # config/mail.rb, as it does for DB_NAME.
      helper = read(dest, "test/test_helper.rb")
      dotenv_at = helper.index("Dotenv.load(env_test)")
      refute_nil dotenv_at, "expected the test helper to load .env.test"
      assert_operator dotenv_at, :<, helper.index('require_relative "../config/load"')
    end
  end

  # --auth sends magic links, so it implies --mail, plus the HTML template
  # for the link.
  def test_write_bang_with_auth_adds_the_mail_scaffold
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, auth: true).write!

      assert_equal template("mail/config/mail.rb"), read(dest, "config/mail.rb")
      assert_equal template("auth/app/views/mail/magic_link.erb"), read(dest, "app/views/mail/magic_link.erb")
      assert_includes read(dest, "Gemfile"), template("mail/Gemfile.extra")
      assert_equal 1, read(dest, "Gemfile").scan("net-smtp").size
    end
  end

  def test_write_bang_with_auth_and_mail_writes_mail_once
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, auth: true, mail: true).write!

      assert_equal 1, read(dest, "Gemfile").scan("net-smtp").size
      assert_equal 1, read(dest, ".env.test").scan("MAIL_URL").size
    end
  end

  def test_config_auth_doesnt_require_config_mail
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, auth: true).write!

      refute_includes read(dest, "config/auth.rb"), %(require_relative "mail")
    end
  end

  def test_write_bang_without_auth_scaffolds_no_mail
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      Monk::Scaffold.new(dest, postgres: true).write!

      refute File.exist?(File.join(dest, "config/mail.rb"))
      refute_includes read(dest, "Gemfile"), "net-smtp"
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

      assert_includes read(dest, "SETUP.md"), "MAIL_URL"
    end
  end

  # The scaffolded pieces working together, as a generated app would load
  # them: settings, then mail, then auth, views frozen,
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
                Monk::Views.root = File.join(dest, "app/views")
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

  def run_generated_tests(dest)
    env = { "BUNDLE_GEMFILE" => File.expand_path("../Gemfile", __dir__), "MONK_ENV" => nil }
    script = %(Dir["test/**/*_test.rb"].each { |file| require File.expand_path(file) })
    Open3.capture2e(env, RbConfig.ruby, "-rbundler/setup", "-Itest", "-e", script, chdir: dest)
  end

  def read(dest, relative)
    File.read(File.join(dest, relative))
  end
end
