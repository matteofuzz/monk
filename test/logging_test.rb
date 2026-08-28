require_relative "test_helper"
require "stringio"

class LoggingTest < Minitest::Test
  def test_logs_method_path_status_and_duration_to_stdout
    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    output = with_monk_env("development") { capture_stdout { app.call(env_for("GET", "/x")) } }

    assert_match(%r{\AGET /x -> 200 \(\d+(\.\d+)?ms\)\n\z}, output)
  end

  def test_does_not_log_when_monk_env_is_production
    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    output = with_monk_env("production") { capture_stdout { app.call(env_for("GET", "/x")) } }

    assert_equal "", output
  end

  private

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
