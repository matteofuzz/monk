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
      assert_equal template("base/.ruby-version"), read(dest, ".ruby-version")
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
      base_dest = File.join(tmp, "base_app")
      postgres_dest = File.join(tmp, "postgres_app")
      Monk::Scaffold.new(base_dest).write!
      Monk::Scaffold.new(postgres_dest, postgres: true).write!

      base_gemfile = read(base_dest, "Gemfile")
      postgres_gemfile = read(postgres_dest, "Gemfile")

      assert postgres_gemfile.start_with?(base_gemfile)
      assert_equal "\n" + template("postgres/Gemfile.extra"), postgres_gemfile.delete_prefix(base_gemfile)
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
