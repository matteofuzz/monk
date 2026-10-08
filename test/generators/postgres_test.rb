require_relative "../test_helper"
require "pg"

# monk add postgres (docs/plan-scaffold.md, "postgres").
class GeneratorsPostgresTest < Minitest::Test
  include GeneratorTestHelpers
  include PersistenceTestHelpers

  def test_writes_the_persistence_wiring
    with_new_app(:postgres) do |dest|
      assert_equal template("postgres/config/persistence.rb"), generated(dest, "config/persistence.rb")
      %w[bin/console bin/setup_db bin/migrate].each { |script| assert File.executable?(File.join(dest, script)) }
      assert_equal [".keep"], Dir.children(File.join(dest, "db/migrate"))
      assert_includes generated(dest, "Gemfile"), %(gem "pg", "~> 1.6")
      assert_includes generated(dest, "Gemfile"), %(gem "irb")
    end
  end

  # The database names come from the app's directory, the one per-app value.
  def test_env_files_name_the_apps_own_databases
    with_new_app(:postgres) do |dest|
      assert_includes generated(dest, ".env"), "DB_NAME=shop_development\n"
      assert_includes generated(dest, ".env.test"), "DB_NAME=shop_test\n"
      assert_includes generated(dest, ".env.example"), "DB_NAME=shop_development\n"
      assert_includes generated(dest, ".env.test"), "DB_HOST=127.0.0.1\n"
    end
  end

  def test_sections_say_how_to_start_postgres_for_this_app
    with_new_app(:postgres) do |dest|
      assert_includes generated(dest, "SETUP.md"), "--name shop_pg postgres:16"
      assert_includes generated(dest, "SETUP.md"), "DB_NAME=shop_test bin/setup_db"
      assert_includes generated(dest, "AGENTS.md"), "<!-- monk:module postgres -->\n## postgres\n"
    end
  end

  def test_reports_the_service_and_the_steps
    with_new_app do |dest|
      result = add_modules(dest, :postgres)

      assert_equal [{ name: "postgres", check: "pg_isready -h 127.0.0.1 -p 5432", setup: "SETUP.md#postgres" }],
        result.services
      assert_equal [{ run: "bundle install" },
                    { do: "start Postgres and create the databases (SETUP.md › postgres)", module: :postgres },
                    { run: "bundle exec rake test", needs_service: "postgres" },], result.next_steps
      assert_equal [{ tag: "postgres-model", path: "app/routes/postgres.rb", line: 3, module: :postgres,
                      todo: "uncomment, then move the table to a migration and the model to app/models/", }],
        result.examples
    end
  end

  def test_the_apps_own_tests_pass_and_bin_setup_db_runs
    with_new_app(:postgres) do |dest|
      with_generated_database do |env|
        out, status = run_generated_script(dest, "bin/setup_db", env)
        assert status.success?, out

        assert_generated_tests_pass(dest, env)
      end
    end
  end
end
