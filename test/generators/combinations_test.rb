require_relative "../test_helper"
require "pg"

# Properties across modules (docs/plan-scaffold.md Phase 6): the order
# modules are added in doesn't matter, adding to an app is the same as
# creating it with them, and every combination works.
class GeneratorsCombinationsTest < Minitest::Test
  include GeneratorTestHelpers
  include PersistenceTestHelpers
  include RedisTestHelpers

  MODULES = %i[postgres redis mail auth jobs websocket live].freeze
  # websocket and live need a transport; Postgres, so a pair adds it.
  OPTIONS = { transport: "postgres" }.freeze

  # A then B, B then A, and both in one command give the same app, up to
  # what legitimately depends on the order: migration timestamps (each
  # run's own), the order of appended lines, and of SETUP.md and
  # AGENTS.md's sections. Every copied file is byte for byte the same.
  def test_the_order_modules_are_added_in_doesnt_matter
    MODULES.combination(2).each do |first, second|
      one_then_other = app_tree { |dest| add_each(dest, first, second) }
      other_then_one = app_tree { |dest| add_each(dest, second, first) }
      together = app_tree { |dest| add_modules(dest, first, second, options: OPTIONS) }

      assert_equal one_then_other, other_then_one, "#{first} then #{second}, against #{second} then #{first}"
      assert_equal one_then_other, together, "#{first} then #{second}, against both at once"
    end
  end

  # `monk add` on an app is `monk new --with`: the base, then the modules.
  def test_adding_to_an_app_is_the_same_as_creating_it_with_the_modules
    added = app_tree(base: false) { |dest| add_each(dest, :base) && add_modules(dest, *MODULES, options: OPTIONS) }
    created = app_tree(base: false) { |dest| add_modules(dest, :base, *MODULES, options: OPTIONS) }

    assert_equal added, created
  end

  def test_the_transport_is_inferred_across_one_command
    with_new_app(:jobs, :live) { |dest| assert_includes generated(dest, "config/websocket.rb"), "PgFanout" }
    with_new_app(:redis, :live) { |dest| assert_includes generated(dest, "config/websocket.rb"), "RedisFanout" }

    with_new_app do |dest|
      assert_equal :missing_choice, add_modules(dest, :live).status
      assert_equal :missing_choice, add_modules(dest, :postgres, :redis, :live).status
    end
  end

  # Every pair, and everything over each transport, works: the generated
  # app migrates and passes its own tests. SLOW=1 runs every combination.
  def test_every_combination_works
    skip_unless_postgres_available
    skip_unless_redis_available

    combinations.each do |modules, options|
      with_new_app(*modules, options: options) do |dest|
        with_generated_database { |database| assert_app_works(dest, database, "#{modules.inspect} #{options.inspect}") }
      end
    end
  end

  private

  def add_each(dest, *modules)
    modules.each { |name| add_modules(dest, name, options: OPTIONS) }
  end

  def assert_app_works(dest, database, label)
    env = database.merge("REDIS_URL" => redis_test_url)
    if File.exist?(File.join(dest, "bin/setup_db"))
      out, status = run_generated_script(dest, "bin/setup_db", env)
      assert status.success?, "#{label}: #{out}"
    end

    out, status = run_generated_tests(dest, env)
    assert status.success?, "#{label}:\n#{out}"
  end

  def combinations
    sizes = ENV["SLOW"] ? (1..MODULES.size) : [2]
    sets = sizes.flat_map { |size| MODULES.combination(size).to_a }
    runs = sets.flat_map do |set|
      next [[set, {}]] unless set.intersect?(%i[websocket live])

      %w[postgres redis].map { |transport| [set, { transport: transport }] }
    end
    runs + %w[postgres redis].map { |transport| [MODULES, { transport: transport }] }
  end

  # The app's files after the block, normalized as the test above says.
  def app_tree(base: true)
    Dir.mktmpdir("monk-tree") do |tmp|
      dest = File.join(tmp, "shop")
      FileUtils.mkdir_p(dest)
      add_modules(dest, :base) if base
      yield dest
      tree(dest)
    end
  end

  def tree(dest)
    paths = Dir.glob("**/*", File::FNM_DOTMATCH, base: dest).select { |path| File.file?(File.join(dest, path)) }
    paths.sort.to_h do |path|
      [path.sub(%r{\Adb/migrate/\d+_}, "db/migrate/<stamp>_"), normalized(path, File.read(File.join(dest, path)))]
    end
  end

  def normalized(path, content)
    case path
    when "SETUP.md", "AGENTS.md" then content.split(/^(?=<!-- monk:module )/).map(&:strip).sort
    when "Gemfile", /\A\.env/, ".gitignore", ".dockerignore" then content.lines.map(&:chomp).reject(&:empty?).sort
    else content
    end
  end
end
