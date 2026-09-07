require_relative "test_helper"
require "tmpdir"
require "open3"

class ExeMonkTest < Minitest::Test
  EXE = File.expand_path("../exe/monk", __dir__)

  def test_new_creates_a_project_at_the_given_path
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      stdout, _stderr, status = run_monk("new", dest)

      assert status.success?
      assert File.exist?(File.join(dest, "Gemfile"))
      assert File.exist?(File.join(dest, "config.ru"))
      refute File.exist?(File.join(dest, "bin/migrate"))
      assert_match(/#{Regexp.escape(dest)}/, stdout)
    end
  end

  def test_new_with_postgres_adds_the_persistence_scaffold
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      _stdout, _stderr, status = run_monk("new", dest, "--postgres")

      assert status.success?
      assert File.exist?(File.join(dest, "bin/migrate"))
    end
  end

  def test_new_with_auth_adds_the_auth_scaffold_and_implies_postgres
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      stdout, _stderr, status = run_monk("new", dest, "--auth")

      assert status.success?
      assert File.exist?(File.join(dest, "config/auth.rb"))
      assert File.exist?(File.join(dest, "db/migrate/00000000000001_create_auth_tables.up.sql"))
      assert File.exist?(File.join(dest, "bin/migrate")) # postgres scaffold, implied by --auth
      assert_match(/AUTH_SECRET/, stdout)
    end
  end

  def test_missing_app_name_prints_usage_and_exits_non_zero
    _stdout, stderr, status = run_monk("new")

    refute status.success?
    assert_match(/usage/i, stderr)
  end

  def test_unknown_subcommand_prints_usage_and_exits_non_zero
    _stdout, stderr, status = run_monk("nope")

    refute status.success?
    assert_match(/usage/i, stderr)
  end

  def test_help_variants_print_help_to_stdout_and_exit_successfully
    [[], ["help"], ["--help"], ["-h"]].each do |args|
      stdout, _stderr, status = run_monk(*args)

      assert status.success?, "expected `monk #{args.join(" ")}` to exit successfully"
      assert_match(/Usage: monk new APP_NAME/, stdout)
      assert_match(/--postgres/, stdout)
      assert_match(/--auth/, stdout)
      assert_match(/bin\/migrate/, stdout)
    end
  end

  private

  def run_monk(*args)
    Open3.capture3(EXE, *args)
  end
end
