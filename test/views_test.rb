require_relative "test_helper"

class ViewsTest < Minitest::Test
  # --- compilation and escaping (Seam V) ---

  def test_compiled_template_renders_its_static_content
    with_views("index.erb" => "<p>hi</p>\n") do
      app = boot_app { get("/") { render "index" } }

      _status, _headers, body = app.call(env_for("GET", "/"))

      assert_equal "<p>hi</p>\n", body.join
    end
  end

  def test_interpolation_is_html_escaped_by_default
    with_views("index.erb" => "<h1><%= params[:name] %></h1>") do
      app = boot_app { get("/") { render "index" } }

      _status, _headers, body = app.call(env_for("GET", "/").merge("QUERY_STRING" => "name=%3Cscript%3E"))

      assert_equal "<h1>&lt;script&gt;</h1>", body.join
    end
  end

  def test_raw_opts_out_of_escaping
    with_views("index.erb" => %(<%= raw("<em>trusted</em>") %>)) do
      app = boot_app { get("/") { render "index" } }

      _status, _headers, body = app.call(env_for("GET", "/"))

      assert_equal "<em>trusted</em>", body.join
    end
  end

  def test_explicit_h_is_not_escaped_twice
    with_views("index.erb" => %(<%= h("<b>") %>)) do
      app = boot_app { get("/") { render "index" } }

      _status, _headers, body = app.call(env_for("GET", "/"))

      assert_equal "&lt;b&gt;", body.join
    end
  end

  def test_control_flow_and_newline_trimming
    with_views("index.erb" => "<% 2.times do |i| -%>\n<li><%= i %></li>\n<% end -%>\n") do
      app = boot_app { get("/") { render "index" } }

      _status, _headers, body = app.call(env_for("GET", "/"))

      assert_equal "<li>0</li>\n<li>1</li>\n", body.join
    end
  end

  # --- data reaching a template ---

  def test_locals_hash_reaches_the_template
    with_views("index.erb" => "<%= locals[:label] %>") do
      app = boot_app { get("/") { render "index", label: "from-locals" } }

      _status, _headers, body = app.call(env_for("GET", "/"))

      assert_equal "from-locals", body.join
    end
  end

  def test_an_undeclared_local_is_simply_absent
    with_views("index.erb" => "<%= locals[:missing].inspect %>") do
      app = boot_app { get("/") { render "index" } }

      _status, _headers, body = app.call(env_for("GET", "/"))

      assert_equal "nil", body.join
    end
  end

  def test_ivars_set_in_the_route_are_visible_to_template_and_layout
    templates = {
      "layouts/app.erb" => "<title><%= @title %></title><%= yield %>",
      "index.erb" => "<h1><%= @title %></h1>",
    }

    with_views(templates) do
      app = boot_app(layout: "layouts/app") do
        get("/") { @title = "Home"; render "index" }
      end

      _status, _headers, body = app.call(env_for("GET", "/"))

      assert_equal "<title>Home</title><h1>Home</h1>", body.join
    end
  end

  # --- partials ---

  def test_a_template_can_render_another_without_double_escaping
    templates = {
      "index.erb" => %(<ul><% 2.times { |i| %><%= render "row", n: i %><% } %></ul>),
      "row.erb" => "<li><%= locals[:n] %></li>",
    }

    with_views(templates) do
      app = boot_app { get("/") { render "index" } }

      _status, _headers, body = app.call(env_for("GET", "/"))

      assert_equal "<ul><li>0</li><li>1</li></ul>", body.join
    end
  end

  def test_a_nested_render_does_not_get_wrapped_in_the_layout
    templates = {
      "layouts/app.erb" => "[<%= yield %>]",
      "index.erb" => %(<%= render "row" %>),
      "row.erb" => "row",
    }

    with_views(templates) do
      app = boot_app(layout: "layouts/app") { get("/") { render "index" } }

      _status, _headers, body = app.call(env_for("GET", "/"))

      assert_equal "[row]", body.join
    end
  end

  # --- layouts ---

  def test_default_layout_wraps_the_page_via_yield
    templates = { "layouts/app.erb" => "<body><%= yield %></body>", "index.erb" => "<p>x</p>" }

    with_views(templates) do
      app = boot_app(layout: "layouts/app") { get("/") { render "index" } }

      _status, _headers, body = app.call(env_for("GET", "/"))

      assert_equal "<body><p>x</p></body>", body.join
    end
  end

  def test_layout_false_skips_the_default_layout
    templates = { "layouts/app.erb" => "<body><%= yield %></body>", "row.erb" => "<p>x</p>" }

    with_views(templates) do
      app = boot_app(layout: "layouts/app") { get("/") { render "row", layout: false } }

      _status, _headers, body = app.call(env_for("GET", "/"))

      assert_equal "<p>x</p>", body.join
    end
  end

  def test_an_explicit_layout_overrides_the_default
    templates = {
      "layouts/app.erb" => "<body><%= yield %></body>",
      "layouts/print.erb" => "<print><%= yield %></print>",
      "index.erb" => "x",
    }

    with_views(templates) do
      app = boot_app(layout: "layouts/app") { get("/") { render "index", layout: "layouts/print" } }

      _status, _headers, body = app.call(env_for("GET", "/"))

      assert_equal "<print>x</print>", body.join
    end
  end

  def test_the_layout_sees_the_same_locals_as_the_page
    templates = { "layouts/app.erb" => "<%= locals[:title] %>|<%= yield %>", "index.erb" => "page" }

    with_views(templates) do
      app = boot_app(layout: "layouts/app") { get("/") { render "index", title: "T" } }

      _status, _headers, body = app.call(env_for("GET", "/"))

      assert_equal "T|page", body.join
    end
  end

  # --- discovery and boot (Seams V, B) ---

  def test_boot_compiles_nested_templates_addressable_by_relative_path
    with_views("posts/row.erb" => "a row") do
      app = boot_app { get("/") { render "posts/row" } }

      _status, _headers, body = app.call(env_for("GET", "/"))

      assert_equal "a row", body.join
    end
  end

  def test_a_template_syntax_error_fails_the_boot_naming_file_and_line
    with_views("bad.erb" => "<% if true %>\nunclosed\n") do
      error = assert_raises(Monk::TemplateSyntaxError) do
        boot_app { get("/") { "unused" } }
      end

      assert_includes error.message, "bad.erb"
      assert_includes error.message, ":3"
    end
  end

  def test_a_layout_that_does_not_exist_fails_the_boot
    with_views("index.erb" => "x") do
      error = assert_raises(Monk::TemplateNotFoundError) do
        boot_app(layout: "layouts/missing") { get("/") { render "index" } }
      end

      assert_includes error.message, "layouts/missing"
      assert_includes error.message, "layout"
    end
  end

  def test_rendering_an_unknown_template_raises_naming_the_root
    with_views("index.erb" => "x") do
      boot_app { get("/") { render "index" } }

      error = assert_raises(Monk::TemplateNotFoundError) do
        Monk::Views.render(Monk::Context.new({}), "nope", {})
      end

      assert_includes error.message, '"nope"'
      assert_includes error.message, Monk::Views.root
      assert_includes error.message, '"index"'
    end
  end

  def test_the_views_registry_is_shareable_after_boot
    with_views("index.erb" => "x") do
      boot_app { get("/") { render "index" } }

      assert Ractor.shareable?(Monk::Views.registry)
    end
  end

  def test_an_app_with_no_views_directory_boots_unchanged
    Monk::Views.reset!
    Monk::Views.root = File.join(Dir.tmpdir, "monk-nonexistent-views")

    app = Class.new(Monk::Base) { get("/") { "plain" } }
    Monk.boot(app)

    _status, _headers, body = app.call(env_for("GET", "/"))

    assert_equal "plain", body.join
  ensure
    Monk::Views.reset!
  end

  # --- errors inside templates ---

  def test_a_backtrace_from_a_template_points_at_the_erb_file_and_line
    with_views("boom.erb" => "one\ntwo\n<% raise \"kaput\" %>\n") do
      boot_app { get("/") { render "boom" } }

      error = assert_raises(RuntimeError) do
        Monk::Views.render(Monk::Context.new({}), "boom", {})
      end

      assert_match(%r{boom\.erb:3}, error.backtrace.first)
    end
  end

  def test_an_exception_in_a_template_reaches_the_apps_error_handler
    with_views("boom.erb" => "<% raise ArgumentError, \"bad\" %>") do
      app = boot_app do
        get("/") { render "boom" }
        error(ArgumentError) { json(error: "handled") }
      end

      status, headers, body = app.call(env_for("GET", "/"))

      assert_equal 500, status
      assert_equal "application/json", headers["content-type"]
      assert_equal '{"error":"handled"}', body.join
    end
  end

  # --- the Rack boundary (Seam W) ---

  def test_render_sets_the_html_content_type
    with_views("index.erb" => "<p>x</p>") do
      app = boot_app { get("/") { render "index" } }

      status, headers, _body = app.call(env_for("GET", "/"))

      assert_equal 200, status
      assert_equal "text/html; charset=utf-8", headers["content-type"]
    end
  end

  def test_a_route_that_renders_then_returns_json_keeps_the_json_content_type
    with_views("index.erb" => "<p>x</p>") do
      app = boot_app { get("/") { render "index"; json(ok: true) } }

      _status, headers, body = app.call(env_for("GET", "/"))

      assert_equal "application/json", headers["content-type"]
      assert_equal '{"ok":true}', body.join
    end
  end

  def test_halt_after_a_render_returns_exactly_the_halt_response
    with_views("index.erb" => "<p>x</p>") do
      app = boot_app { get("/") { render "index"; halt 401, "nope" } }

      status, _headers, body = app.call(env_for("GET", "/"))

      assert_equal 401, status
      assert_equal "nope", body.join
    end
  end

  private

  def boot_app(layout: nil, &block)
    root = Monk::Views.root
    app = Class.new(Monk::Base, &block)
    app.views(root)
    app.layout(layout) if layout
    Monk.boot(app)
    app
  end
end
