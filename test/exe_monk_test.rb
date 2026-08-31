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

  def test_no_arguments_prints_usage_and_exits_non_zero
    _stdout, stderr, status = run_monk

    refute status.success?
    assert_match(/usage/i, stderr)
  end

  private

  def run_monk(*args)
    Open3.capture3(EXE, *args)
  end
end
