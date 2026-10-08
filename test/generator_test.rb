require_relative "test_helper"
require "json"
require "monk/generator"

# The generator engine (docs/plan-scaffold.md Phase 3), on fake modules
# and templates of its own, before any real module exists: what a run
# writes, what it never writes, and what it reports.
class GeneratorTest < Minitest::Test
  NOW = Time.utc(2026, 10, 8, 14, 30, 0)

  def setup
    @templates = Dir.mktmpdir("monk-templates")
    @app = File.join(Dir.mktmpdir("monk-app"), "shop")
    FileUtils.mkdir_p(@app)
    write_templates
    @registry = build_registry
  end

  def teardown
    FileUtils.rm_rf(@templates)
    FileUtils.rm_rf(File.dirname(@app))
  end

  # --- what gets written ---

  def test_copies_files_verbatim_and_marks_executables
    result = add(:db)

    assert_equal :ok, result.status
    assert_equal "DB = :configured\n", app_file("config/db.rb")
    assert File.executable?(File.join(@app, "bin/db"))
    assert_equal 0, result.exit_code
  end

  def test_adding_an_installed_module_changes_nothing
    add(:db)
    before = snapshot

    result = add(:db)

    assert_equal :ok, result.status
    refute result.written
    assert_equal [{ name: :db, action: :already_installed }], result.modules
    assert_equal "db is already installed — nothing to do.\n", result.to_text
    assert_equal before, snapshot
  end

  def test_gems_are_appended_once_and_an_existing_gem_is_left_alone
    File.write(File.join(@app, "Gemfile"), %(source "https://rubygems.org"\ngem "fakeredis", "~> 9"\n))

    add(:db, :cache)

    gemfile = app_file("Gemfile")
    assert_equal 1, gemfile.scan('gem "fakepg"').size
    assert_includes gemfile, %(gem "fakeredis", "~> 9"), "the app's own line wins"
    refute_includes gemfile, %(gem "fakeredis", "~> 5")
  end

  def test_env_lines_are_appended_and_an_existing_key_keeps_its_value
    File.write(File.join(@app, ".env"), "DB_HOST=db.internal\n")

    add(:db)

    env = app_file(".env")
    assert_includes env, "DB_HOST=db.internal\n"
    refute_includes env, "DB_HOST=127.0.0.1"
    assert_includes env, "DB_NAME=shop_development\n", "a value block gets the app's name"
    assert_includes app_file(".env.test"), "DB_NAME=shop_test\n"
    assert_includes app_file(".env.example"), "# DB_PASSWORD=\n", "commented lines stay commented"
  end

  def test_ignore_lines_go_to_gitignore_and_dockerignore_once
    File.write(File.join(@app, ".gitignore"), "/log/\n/db-data/\n")

    add(:db)

    assert_equal "/log/\n/db-data/\n", app_file(".gitignore")
    assert_equal "/db-data/\n", app_file(".dockerignore")
  end

  def test_migrations_get_this_runs_timestamps_in_order_and_are_added_once
    result = add(:db, :login)

    assert_equal %w[20261008143000_create_things.down.sql 20261008143000_create_things.up.sql
                    20261008143001_create_logins.down.sql 20261008143001_create_logins.up.sql],
      Dir.children(File.join(@app, "db/migrate")).sort
    assert_equal "CREATE TABLE things ();\n", app_file("db/migrate/20261008143000_create_things.up.sql")
    assert_includes result.next_steps, { run: "bin/setup_db", needs_service: "db" }

    @registry.fetch(:db).installed_if("config/never.rb") # force db to run again
    add(:db, now: NOW + 3600)

    assert_equal 4, Dir.children(File.join(@app, "db/migrate")).size, "a migration with that name is already there"
  end

  def test_sections_are_appended_once_with_the_app_name
    add(:db)
    add(:login)

    setup = app_file("SETUP.md")
    assert_equal 1, setup.scan("<!-- monk:module db -->").size
    assert_includes setup, "docker run --name shop_db"
    assert_includes app_file("AGENTS.md"), "<!-- monk:module login -->\n## login\n"
  end

  # --- dependencies and options ---

  def test_dependencies_are_added_first_and_say_who_needed_them
    result = add(:login)

    assert_equal(%i[db mailer login], result.modules.map { |entry| entry[:name] })
    assert_equal "needed by login", result.modules.first[:reason]
    assert result.to_text.start_with?("Adding login, which needs db and mailer — adding those first.\n")
  end

  def test_a_dependency_needed_by_two_modules_names_both
    result = add(:login, :sockets, options: { transport: "db" })

    assert_equal "needed by login, sockets", result.modules.find { |entry| entry[:name] == :db }[:reason]
  end

  def test_an_installed_dependency_is_reported_not_added_again
    add(:db)

    result = add(:login)

    assert_includes result.modules, { name: :db, action: :already_installed, reason: "needed by login" }
    assert result.to_text.start_with?("Adding login, which needs mailer — adding it first.\n")
  end

  def test_an_option_is_inferred_from_the_one_installed_candidate
    add(:cache)

    result = add(:sockets)

    assert_equal :ok, result.status
    assert_equal "SOCKETS = :cache\n", app_file("config/sockets.rb")
    assert_equal({ transport: "cache" }, result.modules.last[:options])
  end

  def test_an_option_is_inferred_from_a_module_added_in_the_same_command
    add(:login, :sockets)

    assert_equal "SOCKETS = :db\n", app_file("config/sockets.rb")
  end

  def test_a_chosen_option_adds_its_module
    result = add(:sockets, options: { transport: "cache" })

    assert_equal(%i[cache sockets], result.modules.map { |entry| entry[:name] })
    assert File.exist?(File.join(@app, "config/cache.rb"))
  end

  def test_a_choice_that_cant_be_inferred_writes_nothing_and_names_the_option
    add(:db)
    add(:cache)
    before = snapshot

    result = add(:sockets)

    assert_equal :missing_choice, result.status
    assert_equal 2, result.exit_code
    assert_equal before, snapshot
    assert_equal({ "module" => "sockets", "option" => "transport", "values" => %w[db cache],
                   "reason" => "this app has both db and cache", }, result.to_h["choice"],)
    assert_equal <<~TEXT, result.to_text
      monk add sockets: sockets needs a transport, and this app has both db and cache. Pass one:

        monk add sockets --transport=db      the database carries it
        monk add sockets --transport=cache   needs the cache running

      Nothing was written.
    TEXT
  end

  def test_an_option_value_that_isnt_offered_is_a_usage_error
    result = add(:sockets, options: { transport: "carrier-pigeon" })

    assert_equal :usage_error, result.status
    assert_includes result.message, "--transport=carrier-pigeon isn't one of db, cache"
  end

  def test_an_unknown_module_is_a_usage_error
    result = add(:nope)

    assert_equal 1, result.exit_code
    assert_equal "monk add --list", result.suggestion
    assert result.to_text.end_with?("Nothing was written.\n")
  end

  def test_a_dependency_cycle_is_a_usage_error
    registry = Monk::Generator::Registry.new(templates_dir: @templates)
    registry.define(:egg) { depends_on :hen }
    registry.define(:hen) { depends_on :egg }

    result = registry.add(@app, [:egg], now: NOW)

    assert_equal :usage_error, result.status
    assert_includes result.message, "egg -> hen -> egg"
  end

  # A flag-like option (live's --no-demo) has a default instead of being
  # inferred, and files, steps and the closing line can depend on it.
  def test_an_option_with_a_default_switches_files_steps_and_closing
    result = add(:widget)

    assert File.exist?(File.join(@app, "app/widget_demo.rb"))
    assert_includes result.next_steps, { do: "open the demo" }
    assert_equal "Remove the demo when done.", result.closing

    FileUtils.rm_rf(Dir.children(@app).map { |child| File.join(@app, child) })
    result = add(:widget, options: { demo: "off" })

    refute File.exist?(File.join(@app, "app/widget_demo.rb"))
    refute_includes result.next_steps, { do: "open the demo" }
    assert_nil result.closing
  end

  # The first section in a new SETUP.md starts it, without a blank line.
  def test_a_section_starts_a_new_file_without_a_blank_line
    add(:db)

    assert app_file("SETUP.md").start_with?("<!-- monk:module db -->\n## db\n")
  end

  # --- conflicts ---

  def test_a_wiring_conflict_stops_everything_before_anything_is_written
    write_app_file("bin/db", "#!/bin/sh\necho mine\n")
    before = snapshot

    result = add(:login)

    assert_equal :conflict, result.status
    assert_equal 3, result.exit_code
    assert_equal before, snapshot, "not even the modules without a conflict"
    assert_equal <<~TEXT, result.to_text
      bin/db exists and differs, and db needs it to run.
        Monk's version of bin/db: monk help db --file bin/db

      Nothing was written.
    TEXT
  end

  def test_any_other_conflict_is_skipped_and_the_module_still_added
    write_app_file("test/login_test.rb", "# my own\n")

    result = add(:login)

    assert_equal :ok, result.status
    assert_equal "# my own\n", app_file("test/login_test.rb")
    assert File.exist?(File.join(@app, "config/login.rb"))
    assert_equal [{ path: "test/login_test.rb", module: :login, role: :test,
                    show: "monk help login --file test/login_test.rb", }], result.skipped
    assert_includes result.to_text, "  ! test/login_test.rb             exists and differs — left as is"
  end

  def test_a_file_that_already_matches_is_not_a_conflict
    write_app_file("config/cache.rb", "CACHE = true\n")

    result = add(:cache)

    assert_empty result.skipped
    refute(result.files.any? { |entry| entry[:path] == "config/cache.rb" })
  end

  # --- dry run ---

  def test_a_dry_run_reports_everything_and_writes_nothing
    result = add(:login, dry_run: true)

    assert_equal [], Dir.children(@app)
    refute result.written
    assert(result.files.any? { |entry| entry[:path] == "config/login.rb" })
    assert result.to_text.start_with?(
      "Would add login, which needs db and mailer — adding those first (nothing written):\n",
    )
    assert result.to_h["dry_run"]
  end

  # --- what gets reported ---

  def test_examples_are_found_with_their_line_and_todo
    add(:cache)

    result = add(:login)

    assert_includes result.examples, { tag: "login-routes", path: "app/routes/login.rb", line: 2, module: :login,
                                       todo: "uncomment, add a rate limit (cache is installed)", }
    assert_includes result.examples, { tag: "db-model", path: "app/routes/db.rb", line: 1, module: :db,
                                       todo: "uncomment to read a thing", }
  end

  def test_next_steps_in_order_with_the_tests_last
    result = add(:db)

    assert_equal [
      { run: "bundle install" }, { do: "start the db (SETUP.md › db)", needs_service: "db" },
      { run: "bin/setup_db", needs_service: "db" }, { run: "bundle exec rake test", needs_service: "db" },
    ], result.next_steps
  end

  def test_the_text_form
    result = add(:login)

    assert_equal <<~TEXT, result.to_text
      Adding login, which needs db and mailer — adding those first.

      db
        + config/db.rb
        + bin/db
        + app/routes/db.rb               example: db-model (commented)
        + db/migrate/20261008143000_create_things.{up,down}.sql
        ~ Gemfile                        fakepg
        ~ .env, .env.test, .env.example  DB_*
        ~ .gitignore, .dockerignore      /db-data/

      mailer
        + config/mailer.rb

      login
        + config/login.rb
        + app/routes/login.rb            example: login-routes (commented)
        + test/login_test.rb
        + db/migrate/20261008143001_create_logins.{up,down}.sql
        ~ .env                           SECRET

        ~ SETUP.md, AGENTS.md            sections: db, login

      Set before production:
        SECRET  placeholder in .env — replace it

      Next:
        1. bundle install
        2. start the db (SETUP.md › db)
        3. bin/setup_db && bundle exec rake test

      Then enable the login routes: app/routes/login.rb, block "login-routes".
    TEXT
  end

  # One module: its files straight under the header, no module heading.
  def test_the_text_form_for_one_module
    add(:db)
    @registry.fetch(:mailer).agents_section("login/agents.md")

    assert_equal <<~TEXT, add(:mailer).to_text
      Adding mailer.

        + config/mailer.rb
        ~ AGENTS.md                      section: mailer

      Next:
        1. bundle exec rake test
    TEXT
  end

  def test_more_than_three_steps_keep_the_first_two_and_the_tests
    @registry.fetch(:login).next_step("bin/login_worker")

    text = add(:login).to_text

    assert_includes text, "  1. bundle install\n  2. start the db (SETUP.md › db)\n  " \
                          "3. bin/setup_db && bundle exec rake test\n  … and the rest in SETUP.md\n"
    assert_includes add(:cache, dry_run: true).to_text, "Would add cache (nothing written):"
  end

  def test_the_json_form
    json = JSON.parse(add(:login).to_json)

    assert_equal "ok", json["status"]
    assert_equal true, json["written"]
    assert_equal({ "name" => "db", "action" => "added", "reason" => "needed by login" }, json["modules"].first)
    assert_includes json["files"],
      { "path" => "config/login.rb", "module" => "login", "role" => "wiring", "action" => "created" }
    assert_includes json["files"],
      { "path" => "Gemfile", "module" => "db", "action" => "appended", "items" => ["fakepg"] }
    assert_includes json["files"], { "path" => "SETUP.md", "action" => "appended", "items" => %w[db login] }
    assert_equal [{ "key" => "SECRET", "files" => [".env"], "placeholder" => true,
                    "required_in" => %w[staging production], "note" => "placeholder in .env — replace it", }],
      json["env"]
    assert_equal [{ "name" => "db", "check" => "fake_isready", "setup" => "SETUP.md#db" }], json["services"]
    assert_equal({ "run" => "bundle exec rake test", "needs_service" => "db" }, json["next"].last)
    assert_equal %w[SETUP.md#db SETUP.md#login AGENTS.md#db AGENTS.md#login], json["docs"]
  end

  private

  def add(*modules, now: NOW, **)
    @registry.add(@app, modules, now: now, **)
  end

  def build_registry
    registry = Monk::Generator::Registry.new(templates_dir: @templates)
    registry.define(:db) do
      summary "A database"
      copy "config/db.rb", "bin/db", role: :wiring, executable: true
      copy "app/routes/db.rb", role: :example
      migration "create_things"
      gem %(gem "fakepg", "~> 1.0")
      env :development, { "DB_HOST" => "127.0.0.1", "DB_NAME" => ->(app) { "#{app}_development" } }
      env :test, { "DB_HOST" => "127.0.0.1", "DB_NAME" => ->(app) { "#{app}_test" } }
      env :example, { "DB_HOST" => "127.0.0.1" }
      env :example, { "DB_PASSWORD" => "" }, commented: true
      ignore "/db-data/"
      service :db, check: "fake_isready", setup: "SETUP.md#db"
      next_step "start the db (SETUP.md › db)", needs_service: :db
      setup_section "db/setup.md"
      agents_section "db/agents.md"
      example "db-model", todo: "uncomment to read a thing"
    end
    registry.define(:cache) do
      copy "config/cache.rb", role: :wiring
      gem %(gem "fakeredis", "~> 5")
    end
    registry.define(:mailer) { copy "config/mailer.rb", role: :wiring }
    registry.define(:login) do
      depends_on :db, :mailer
      copy "config/login.rb", role: :wiring
      copy "app/routes/login.rb", role: :example
      copy "test/login_test.rb", role: :test
      migration "create_logins"
      env :development, { "SECRET" => "change-me" }
      set_before_production "SECRET", "placeholder in .env — replace it", placeholder: true
      setup_section "login/setup.md"
      agents_section "login/agents.md"
      example "login-routes", todo: lambda { |installed|
        "uncomment, add a rate limit#{" (cache is installed)" if installed.include?("cache")}"
      }
      closing %(Then enable the login routes: app/routes/login.rb, block "login-routes".)
    end
    registry.define(:widget) do
      option :demo, values: %w[on off], default: "on"
      copy "config/widget.rb", role: :wiring
      copy "app/widget_demo.rb", role: :demo, if: ->(options) { options[:demo] == "on" }
      next_step "open the demo", if: ->(options) { options[:demo] == "on" }
      closing ->(options) { "Remove the demo when done." if options[:demo] == "on" }
    end
    registry.define(:sockets) do
      option :transport, values: %w[db cache], dependency: true,
        describe: { db: "the database carries it", cache: "needs the cache running" }
      copy "config/sockets.rb", role: :wiring, from: ->(options) { "sockets/config/sockets_#{options[:transport]}.rb" }
    end
    registry
  end

  def write_templates
    {
      "db/config/db.rb" => "DB = :configured\n",
      "db/bin/db" => "#!/bin/sh\necho db\n",
      "db/app/routes/db.rb" => "# monk:example db-model\n# class App; end\n# monk:end\n",
      "db/db/migrate/00000000000001_create_things.up.sql" => "CREATE TABLE things ();\n",
      "db/db/migrate/00000000000001_create_things.down.sql" => "DROP TABLE things;\n",
      "db/setup.md" => "## db\n\ndocker run --name {{app}}_db\n",
      "db/agents.md" => "## db\n",
      "cache/config/cache.rb" => "CACHE = true\n",
      "mailer/config/mailer.rb" => "MAILER = true\n",
      "login/config/login.rb" => "LOGIN = true\n",
      "login/app/routes/login.rb" => %(# Login routes.\n# monk:example login-routes\n# post("/login") {}\n# monk:end\n),
      "login/test/login_test.rb" => "# login test\n",
      "login/db/migrate/00000000000002_create_logins.up.sql" => "CREATE TABLE logins ();\n",
      "login/db/migrate/00000000000002_create_logins.down.sql" => "DROP TABLE logins;\n",
      "login/setup.md" => "## login\n",
      "login/agents.md" => "## login\n",
      "widget/config/widget.rb" => "WIDGET = true\n",
      "widget/app/widget_demo.rb" => "# demo\n",
      "sockets/config/sockets_db.rb" => "SOCKETS = :db\n",
      "sockets/config/sockets_cache.rb" => "SOCKETS = :cache\n",
    }.each { |path, content| write_file(@templates, path, content) }
  end

  def write_app_file(path, content) = write_file(@app, path, content)
  def app_file(path) = File.read(File.join(@app, path))

  def snapshot
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @app).sort.to_h do |path|
      full = File.join(@app, path)
      [path, File.file?(full) ? File.read(full) : :dir]
    end
  end
end
