require_relative "../test_helper"
require "json"

# monk add storage (docs/plan-storage.md Phase 8): no service, no
# migration and no JS; the upload flow comes as commented examples.
class GeneratorsStorageTest < Minitest::Test
  include GeneratorTestHelpers

  def test_writes_the_storage_config
    with_new_app(:storage) do |dest|
      assert_equal template("storage/config/storage.rb"), generated(dest, "config/storage.rb")
      assert_includes generated(dest, "config/load.rb"), "storage", "config/load.rb already requires it"
    end
  end

  # An unset STORAGE_URL is file://storage/<env>, so development and
  # test need no line, and neither touches the other's files.
  def test_env_lines_only_in_the_example_and_commented
    with_new_app(:storage) do |dest|
      refute File.exist?(File.join(dest, ".env")), "storage alone writes no .env"
      refute File.exist?(File.join(dest, ".env.test"))
      assert_includes generated(dest, ".env.example"), "# STORAGE_URL=s3://"
      assert_includes generated(dest, ".env.example"), "# STORAGE_SECRET="
    end
  end

  def test_ignores_the_storage_directory
    with_new_app(:storage) do |dest|
      %w[.gitignore .dockerignore].each { |file| assert_includes generated(dest, file).lines, "/storage/\n", file }
    end
  end

  def test_writes_the_three_examples_commented
    with_new_app(:storage) do |dest|
      routes = generated(dest, "app/routes/storage.rb")

      %w[storage-upload storage-confirm storage-download].each do |tag|
        assert_includes routes, "# monk:example #{tag}"
      end
      assert_empty routes.lines.grep(/\A[^#\n]/), "every line is a comment"
    end
  end

  def test_needs_no_other_module_and_lists_what_to_set
    with_new_app do |dest|
      result = add_modules(dest, :storage)

      assert_equal([:storage], result.modules.map { |entry| entry[:name] })
      assert_empty result.services
      assert_equal(%w[STORAGE_URL STORAGE_SECRET], result.env.map { |entry| entry[:key] })
      refute Dir.exist?(File.join(dest, "db"))
    end
  end

  def test_adding_storage_again_changes_nothing
    with_new_app(:storage) do |dest|
      before = tree(dest)
      result = add_modules(dest, :storage)

      refute result.written
      assert_equal "storage is already installed — nothing to do.\n", result.to_text
      assert_equal before, tree(dest)
    end
  end

  def test_json_output
    with_new_app do |dest|
      json = JSON.parse(add_modules(dest, :storage).to_json)

      assert_equal "ok", json["status"]
      assert_equal(%w[storage], json["modules"].map { |entry| entry["name"] })
      roles = json["files"].to_h { |entry| [entry["path"], entry["role"]] }
      assert_equal "wiring", roles["config/storage.rb"]
      assert_equal "example", roles["app/routes/storage.rb"]
      assert_equal "test", roles["test/storage_test.rb"]
      tags = json["examples"].map { |entry| entry["tag"] }
      assert_equal(%w[storage-confirm storage-download storage-upload], tags.sort)
    end
  end

  def test_the_apps_own_tests_pass
    with_new_app(:storage) do |dest|
      assert_generated_tests_pass(dest)
      assert Dir.exist?(File.join(dest, "storage/test")), "tests use file://storage/test"
      refute Dir.exist?(File.join(dest, "storage/development"))
    end
  end

  private

  # Every path under dest, with each file's content.
  def tree(dest)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: dest).sort.to_h do |path|
      full = File.join(dest, path)
      [path, File.file?(full) ? File.read(full) : :dir]
    end
  end
end
