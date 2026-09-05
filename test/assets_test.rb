require_relative "test_helper"

class AssetsTest < Minitest::Test
  CSS = "body{font-family:system-ui}\n".freeze

  def test_serves_a_file_with_its_content_type_and_body
    with_assets("css/app.css" => CSS) do
      app = boot_app

      status, headers, body = app.call(env_for("GET", "/css/app.css"))

      assert_equal 200, status
      assert_equal "text/css; charset=utf-8", headers["content-type"]
      assert_equal CSS, body.join
    end
  end

  def test_content_types_cover_the_vanilla_js_stack
    files = { "js/app.js" => "export const x = 1\n", "img/logo.svg" => "<svg/>", "font/i.woff2" => "x" }

    with_assets(files) do
      app = boot_app

      assert_equal "text/javascript; charset=utf-8", app.call(env_for("GET", "/js/app.js"))[1]["content-type"]
      assert_equal "image/svg+xml; charset=utf-8", app.call(env_for("GET", "/img/logo.svg"))[1]["content-type"]
      assert_equal "font/woff2", app.call(env_for("GET", "/font/i.woff2"))[1]["content-type"]
    end
  end

  def test_etag_is_stable_and_if_none_match_gets_a_304
    with_assets("css/app.css" => CSS) do
      app = boot_app

      _status, headers, _body = app.call(env_for("GET", "/css/app.css"))
      etag = headers["etag"]

      assert_equal etag, app.call(env_for("GET", "/css/app.css"))[1]["etag"]

      status, _headers, body = app.call(env_for("GET", "/css/app.css").merge("HTTP_IF_NONE_MATCH" => etag))

      assert_equal 304, status
      assert_empty body
    end
  end

  def test_cache_control_is_revalidate_by_default_and_immutable_for_a_stamped_request
    with_assets("css/app.css" => CSS) do
      app = boot_app
      stamped = Monk::Assets.path_for("/css/app.css")
      version = stamped.split("?v=").last

      _status, headers, _body = app.call(env_for("GET", "/css/app.css"))

      assert_equal "public, max-age=0, must-revalidate", headers["cache-control"]

      _status, headers, _body = app.call(env_for("GET", "/css/app.css").merge("QUERY_STRING" => "v=#{version}"))

      assert_equal "public, max-age=31536000, immutable", headers["cache-control"]
    end
  end

  def test_head_returns_the_headers_with_an_empty_body
    with_assets("css/app.css" => CSS) do
      app = boot_app

      status, headers, body = app.call(env_for("HEAD", "/css/app.css"))

      assert_equal 200, status
      assert_equal CSS.bytesize.to_s, headers["content-length"]
      assert_empty body
    end
  end

  def test_an_unknown_asset_path_falls_through_to_routing
    with_assets("css/app.css" => CSS) do
      app = boot_app { get("/css/other.css") { "from a route" } }

      _status, _headers, body = app.call(env_for("GET", "/css/other.css"))

      assert_equal "from a route", body.join
    end
  end

  def test_an_unknown_asset_path_still_reaches_the_apps_404_handler
    with_assets("css/app.css" => CSS) do
      app = boot_app { error(404) { json(error: "not found") } }

      status, _headers, body = app.call(env_for("GET", "/css/missing.css"))

      assert_equal 404, status
      assert_equal '{"error":"not found"}', body.join
    end
  end

  def test_an_asset_wins_over_a_splat_route_at_the_same_path
    with_assets("css/app.css" => CSS) do
      app = boot_app { get("/*") { "the splat route" } }

      _status, _headers, body = app.call(env_for("GET", "/css/app.css"))

      assert_equal CSS, body.join
    end
  end

  def test_traversal_is_not_served_in_production
    with_assets("css/app.css" => CSS) do
      app = boot_app

      %w[/../../etc/passwd /css/../../../etc/passwd /%2e%2e/%2e%2e/etc/passwd].each do |path|
        status, _headers, _body = app.call(env_for("GET", path))

        assert_equal 404, status, "expected #{path} not to be served"
      end
    end
  end

  def test_traversal_is_not_served_in_development
    with_assets("css/app.css" => CSS) do
      app = with_monk_env("development") { boot_app }

      %w[/../../etc/passwd /css/../../../etc/passwd].each do |path|
        status, _headers, _body = app.call(env_for("GET", path))

        assert_equal 404, status, "expected #{path} not to be served"
      end
    end
  end

  def test_asset_path_stamps_in_production_but_not_in_development
    with_assets("css/app.css" => CSS) do
      boot_app

      assert_match(%r{\A/css/app\.css\?v=[0-9a-f]{16}\z}, Monk::Assets.path_for("/css/app.css"))
      assert_equal "/css/unknown.css", Monk::Assets.path_for("/css/unknown.css")

      with_monk_env("development") { boot_app }

      assert_equal "/css/app.css", Monk::Assets.path_for("/css/app.css")
    end
  end

  def test_development_reflects_an_edit_without_a_restart
    with_assets("css/app.css" => CSS) do |dir|
      app = with_monk_env("development") { boot_app }

      write_file(dir, "css/app.css", "body{color:red}\n")

      _status, headers, body = app.call(env_for("GET", "/css/app.css"))

      assert_equal "body{color:red}\n", body.join
      assert_equal "no-cache", headers["cache-control"]
    end
  end

  def test_production_serves_the_boot_time_body_after_the_file_changes
    with_assets("css/app.css" => CSS) do |dir|
      app = boot_app

      write_file(dir, "css/app.css", "body{color:red}\n")

      _status, _headers, body = app.call(env_for("GET", "/css/app.css"))

      assert_equal CSS, body.join
    end
  end

  def test_assets_false_disables_serving_entirely
    with_assets("css/app.css" => CSS) do
      app = Class.new(Monk::Base) { error(404) { json(error: "not found") } }
      app.assets(false)
      Monk.boot(app)

      status, _headers, _body = app.call(env_for("GET", "/css/app.css"))

      assert_equal 404, status
    end
  end

  def test_the_manifest_is_shareable_after_boot
    with_assets("css/app.css" => CSS) do
      boot_app

      assert Ractor.shareable?(Monk::Assets.manifest)
    end
  end

  def test_a_post_to_an_asset_path_is_never_served_from_the_manifest
    with_assets("css/app.css" => CSS) do
      app = boot_app { post("/css/app.css") { "posted" } }

      _status, _headers, body = app.call(env_for("POST", "/css/app.css"))

      assert_equal "posted", body.join
    end
  end

  private

  def boot_app(&block)
    root = Monk::Assets.root
    app = Class.new(Monk::Base, &block)
    app.assets(root)
    Monk.boot(app)
    app
  end
end
