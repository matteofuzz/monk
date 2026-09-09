require_relative "test_helper"
require "stringio"

class LoggingTest < Minitest::Test
  def test_logs_method_path_status_and_duration_to_stdout
    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    output = with_log { with_monk_env("development") { capture_stdout { app.call(env_for("GET", "/x")) } } }

    assert_match(%r{\AGET /x -> 200 \(\d+(\.\d+)?ms\)\n\z}, output)
  end

  def test_does_not_log_to_stdout_when_monk_env_is_production
    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    output = with_log { with_monk_env("production") { capture_stdout { app.call(env_for("GET", "/x")) } } }

    assert_equal "", output
  end

  def test_logs_to_a_file_named_after_the_environment_regardless_of_console_output
    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    contents = with_log do |dir|
      with_monk_env("production") { app.call(env_for("GET", "/x")) }
      File.read(File.join(dir, "production.log"))
    end

    assert_match(%r{\AGET /x -> 200 \(\d+(\.\d+)?ms\)\n\z}, contents)
  end

  def test_logs_to_a_file_in_development_alongside_stdout
    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    contents = with_log do |dir|
      with_monk_env("development") { capture_stdout { app.call(env_for("GET", "/x")) } }
      File.read(File.join(dir, "development.log"))
    end

    assert_match(%r{\AGET /x -> 200 \(\d+(\.\d+)?ms\)\n\z}, contents)
  end

  def test_logs_to_test_log_under_the_default_test_environment
    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    contents = with_log do |dir|
      app.call(env_for("GET", "/x"))
      File.read(File.join(dir, "test.log"))
    end

    assert_match(%r{\AGET /x -> 200 \(\d+(\.\d+)?ms\)\n\z}, contents)
  end

  def test_appends_across_requests_instead_of_truncating
    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    contents = with_log do |dir|
      app.call(env_for("GET", "/x"))
      app.call(env_for("GET", "/x"))
      File.read(File.join(dir, "test.log"))
    end

    assert_equal 2, contents.lines.size
  end

  def test_level_methods_default_to_info_and_above
    contents = with_log do |dir|
      boot_app!
      Monk::Log.debug("dropped")
      Monk::Log.info("kept")
      Monk::Log.warn("kept too")
      Monk::Log.error("kept as well")
      File.read(File.join(dir, "test.log"))
    end

    assert_equal ["INFO kept\n", "WARN kept too\n", "ERROR kept as well\n"], contents.lines
  end

  def test_log_level_setting_raises_the_threshold
    contents = with_log do |dir|
      with_settings { with_env("LOG_LEVEL", "error") { boot_app! } }
      Monk::Log.warn("dropped")
      Monk::Log.error("kept")
      File.read(File.join(dir, "test.log"))
    end

    assert_equal ["ERROR kept\n"], contents.lines
  end

  def test_log_level_setting_can_lower_the_threshold_to_debug
    contents = with_log do |dir|
      with_settings { with_env("LOG_LEVEL", "debug") { boot_app! } }
      Monk::Log.debug("kept")
      File.read(File.join(dir, "test.log"))
    end

    assert_equal ["DEBUG kept\n"], contents.lines
  end

  def test_invalid_log_level_raises_at_boot
    with_settings do
      with_env("LOG_LEVEL", "verbose") do
        error = assert_raises(Monk::InvalidLogLevelError) { boot_app! }

        assert_match(/verbose/, error.message)
      end
    end
  end

  private

  def boot_app!
    Class.new(Monk::Base) { get("/x") { "hi" } }.freeze!
  end

  def with_monk_env(value)
    original = ENV["MONK_ENV"]
    ENV["MONK_ENV"] = value
    yield
  ensure
    ENV["MONK_ENV"] = original
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
