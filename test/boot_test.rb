require_relative "test_helper"

class BootTest < Minitest::Test
  def test_freeze_makes_a_well_behaved_app_shareable
    app = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    app.freeze!

    assert Ractor.shareable?(app.routes)
  end

  def test_freeze_makes_error_handlers_shareable_too
    app = Class.new(Monk::Base) do
      get("/x") { raise "boom" }
      error(StandardError) { halt 500, "handled" }
      error(404) { halt 404, "nope" }
    end

    app.freeze!

    assert Ractor.shareable?(app.error_handlers)
  end

  def test_freeze_raises_precise_error_naming_the_offending_route
    count = 0
    app = Class.new(Monk::Base) do
      get("/hits") { count += 1 }
    end

    error = assert_raises(Monk::UnshareableRouteError) { app.freeze! }

    assert_match(/GET \/hits/, error.message)
  end

  def test_call_auto_boots_for_classic_style
    app_class = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    status, _headers, body = app_class.call(env_for("GET", "/x"))

    assert_equal 200, status
    assert_equal "hi", body.join
    assert Ractor.shareable?(app_class.routes)
  end

  def test_call_auto_boots_for_modular_style
    app_class = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    status, _headers, body = app_class.new.call(env_for("GET", "/x"))

    assert_equal 200, status
    assert_equal "hi", body.join
    assert Ractor.shareable?(app_class.routes)
  end

  def test_monk_boot_freezes_eagerly_before_any_request_classic_style
    app_class = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    booted = Monk.boot(app_class)

    assert_same app_class, booted
    assert Ractor.shareable?(app_class.routes)
  end

  def test_monk_boot_freezes_eagerly_before_any_request_modular_style
    app_class = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end
    instance = app_class.new

    booted = Monk.boot(instance)

    assert_same instance, booted
    assert Ractor.shareable?(app_class.routes)
  end

  def test_call_does_not_re_freeze_on_subsequent_requests
    app_class = Class.new(Monk::Base) do
      get("/x") { "hi" }
    end

    2.times { app_class.call(env_for("GET", "/x")) }

    status, _headers, body = app_class.call(env_for("GET", "/x"))
    assert_equal 200, status
    assert_equal "hi", body.join
  end
end
