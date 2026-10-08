require_relative "../test_helper"
require "pg"

# monk add auth (docs/plan-scaffold.md, "auth"): needs postgres and mail.
class GeneratorsAuthTest < Minitest::Test
  include GeneratorTestHelpers
  include PersistenceTestHelpers

  def test_adds_postgres_and_mail_first
    with_new_app do |dest|
      result = add_modules(dest, :auth)

      assert_equal(%i[postgres mail auth], result.modules.map { |entry| entry[:name] })
      assert result.to_text.start_with?("Adding auth, which needs postgres and mail — adding those first.\n")
    end
  end

  # Its own mailer file: mail's app_mailer.rb stays mail's (decision 10).
  def test_writes_its_own_mailer_and_the_migration
    with_new_app(:auth) do |dest|
      assert_includes generated(dest, "config/auth.rb"), %(require_relative "../app/mailers/auth_mailer")
      assert_includes generated(dest, "app/mailers/auth_mailer.rb"), "module AuthMailer"
      assert_includes generated(dest, "app/mailers/app_mailer.rb"), "module AppMailer"
      assert_equal %w[20261008143000_create_auth_tables.down.sql 20261008143000_create_auth_tables.up.sql],
        Dir.children(File.join(dest, "db/migrate")).grep(/\.sql\z/).sort
    end
  end

  def test_reports_the_placeholder_secret_and_the_closing_step
    with_new_app do |dest|
      text = add_modules(dest, :auth).to_text

      assert_includes text, "  AUTH_SECRET  placeholder in .env — replace it\n"
      assert_includes text, "  3. bin/setup_db && bundle exec rake test\n"
      assert text.end_with?("(keep the rate limit — AGENTS.md, auth, says why).\n")
    end
  end

  def test_the_apps_own_tests_pass
    with_new_app(:auth) do |dest|
      with_generated_database do |env|
        out, status = run_generated_script(dest, "bin/setup_db", env)
        assert status.success?, out

        assert_generated_tests_pass(dest, env)
      end
    end
  end
end
