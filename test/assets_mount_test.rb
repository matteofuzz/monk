require_relative "test_helper"

# Monk::Assets.mount: a module's own static files, served from inside the
# gem under a /_monk/ prefix (Monk::Live's client at /_monk/live/), the
# same way as the app's public/ -- so a generator never copies them into
# the app (docs/adr/0017).
class AssetsMountTest < Minitest::Test
  JS = "export const ok = true\n".freeze

  def teardown
    Monk::Assets.unmount("/_monk/test")
  end

  def test_serves_a_mounted_file_under_its_prefix
    with_mount("client.js" => JS) do
      _status, headers, body = boot_app.call(env_for("GET", "/_monk/test/client.js"))

      assert_equal "text/javascript; charset=utf-8", headers["content-type"]
      assert_equal JS, body.join
    end
  end

  def test_a_mounted_file_is_stamped_and_cached_like_an_app_asset_in_production
    with_mount("client.js" => JS) do
      app = boot_app
      stamped = Monk::Assets.path_for("/_monk/test/client.js")

      assert_match(/\?v=\h{16}\z/, stamped)
      request = env_for("GET", "/_monk/test/client.js").merge("QUERY_STRING" => stamped.split("?").last)
      _status, headers, = app.call(request)
      assert_equal "public, max-age=31536000, immutable", headers["cache-control"]
    end
  end

  def test_a_mounted_file_is_read_from_disk_in_development
    with_mount("client.js" => JS) do |dir|
      app = with_monk_env("development") { boot_app }
      File.write(File.join(dir, "client.js"), "export const ok = false\n")

      assert_equal "export const ok = false\n", app.call(env_for("GET", "/_monk/test/client.js"))[2].join
    end
  end

  def test_traversal_out_of_a_mount_is_not_served
    with_assets("secret.txt" => "app file") do
      with_mount("client.js" => JS) do
        %w[development test].each do |env|
          app = with_monk_env(env) { boot_app }

          assert_equal 404, app.call(env_for("GET", "/_monk/test/../secret.txt"))[0], env
          assert_equal 404, app.call(env_for("GET", "/_monk/test/../../etc/passwd"))[0], env
        end
      end
    end
  end

  def test_the_apps_own_files_are_still_served_next_to_a_mount
    with_assets("css/app.css" => "a{}") do
      with_mount("client.js" => JS) do
        assert_equal 200, boot_app.call(env_for("GET", "/css/app.css"))[0]
      end
    end
  end

  def test_a_mount_prefix_must_start_with_monk
    assert_raises(ArgumentError) { Monk::Assets.mount("/js/vendor", Dir.pwd) }
  end

  private

  def with_mount(files)
    Dir.mktmpdir("monk-mount") do |dir|
      files.each { |relative, content| write_file(dir, relative, content) }
      Monk::Assets.mount("/_monk/test", dir)
      yield dir
    end
  end

  # As assets_test.rb boots: the app's public/ root, then Monk.boot.
  def boot_app
    root = Monk::Assets.root
    app = Class.new(Monk::Base) { get("/") { "home" } }
    app.assets(root)
    capture_io { Monk.boot(app) }
    app
  end
end
