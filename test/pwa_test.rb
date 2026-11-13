require_relative "test_helper"
require "json"
require "monk/pwa"

# Monk::Pwa (docs/plan-pwa-push.md, part A): configure checks the app's
# manifest and the files it names at boot, <%= monk_head %> links them, and
# the files are served the way a browser installing the app needs.
class PwaTest < Minitest::Test
  MANIFEST = {
    "name" => "Shop", "short_name" => "Shop", "start_url" => "/", "display" => "standalone",
    "theme_color" => "#1f2937",
    "icons" => [
      { "src" => "/icons/icon-192.png", "sizes" => "192x192", "type" => "image/png" },
      { "src" => "/icons/icon-512.png", "sizes" => "512x512", "type" => "image/png" },
    ],
  }.freeze

  def teardown
    Monk::Pwa.reset!
  end

  # --- the boot-time check ---

  def test_configure_reads_the_manifest
    with_public do |root|
      Monk::Pwa.configure(root: root)

      assert Monk::Pwa.configured?
      assert_equal "Shop", Monk::Pwa.manifest["name"]
      assert Ractor.shareable?(Monk::Pwa.manifest)
    end
  end

  def test_a_missing_or_broken_manifest_fails_the_boot
    with_public({ "manifest.webmanifest" => nil }) { |root| assert_invalid(root, "manifest.webmanifest isn't in") }
    with_public({ "manifest.webmanifest" => "{ nope" }) { |root| assert_invalid(root, "isn't valid JSON") }
    with_public({ "manifest.webmanifest" => "[]" }) { |root| assert_invalid(root, "must be a JSON object") }
  end

  def test_the_fields_a_browser_needs_to_install_the_app
    { "name" => "needs a name", "short_name" => "needs a name", "start_url" => "needs a start_url",
      "display" => "needs display", "icons" => "needs an icons list", }.each do |field, message|
      with_public(manifest: MANIFEST.except(field)) { |root| assert_invalid(root, message) }
    end
    with_public(manifest: MANIFEST.merge("display" => "browser")) { |root| assert_invalid(root, "got \"browser\"") }
  end

  # monk add pwa fills {{app}} in; one left means a template copied by hand.
  def test_a_name_still_holding_the_placeholder_fails_the_boot
    with_public(manifest: MANIFEST.merge("short_name" => "{{app}}")) do |root|
      assert_invalid(root, "still has {{app}}")
    end
  end

  def test_it_needs_a_192_and_a_512_icon_for_any_purpose
    small, large = MANIFEST["icons"]
    with_public(manifest: MANIFEST.merge("icons" => [small])) { |root| assert_invalid(root, "needs a 512x512 icon") }

    maskable_only = MANIFEST.merge("icons" => [small, large.merge("purpose" => "maskable")])
    with_public(manifest: maskable_only) { |root| assert_invalid(root, "needs a 512x512 icon") }

    both = MANIFEST.merge("icons" => [small, large.merge("purpose" => "any maskable")])
    with_public(manifest: both) { |root| Monk::Pwa.configure(root: root) }
  end

  def test_every_file_it_links_must_exist
    with_public({ "icons/icon-512.png" => nil }) { |root| assert_invalid(root, "names icon /icons/icon-512.png") }
    with_public({ "sw.js" => nil }) { |root| assert_invalid(root, "links /sw.js") }
    with_public({ "icons/apple-touch-icon.png" => nil }) do |root|
      assert_invalid(root, "links /icons/apple-touch-icon.png")
    end
  end

  def test_an_icon_on_another_origin_is_not_looked_for
    remote_icon = { "src" => "https://cdn.example/i.png", "sizes" => "48x48" }
    remote = MANIFEST.merge("icons" => MANIFEST["icons"] + [remote_icon])
    with_public(manifest: remote) { |root| Monk::Pwa.configure(root: root) }
  end

  def test_an_app_without_assets_cant_use_it
    assert_raises(ArgumentError) { Monk::Pwa.configure(root: false) }
  end

  # --- head tags ---

  def test_nothing_in_the_head_until_configured
    refute(Monk::Context.new({}).head_tags.any? { |tag| tag.include?("manifest") })
  end

  def test_the_head_links_the_manifest_theme_colour_icon_and_register_script
    with_public do |root|
      Monk::Pwa.configure(root: root)
      head = Monk::Context.new({}).monk_head.to_s

      assert_includes head, %(<link rel="manifest" href="/manifest.webmanifest">)
      assert_includes head, %(<meta name="theme-color" content="#1f2937">)
      assert_includes head, %(<link rel="apple-touch-icon" href="/icons/apple-touch-icon.png)
      assert_match(%r{<script type="module" src="/_monk/pwa/register\.js(\?v=\h+)?"></script>}, head)
    end
  end

  def test_no_theme_colour_meta_without_one_in_the_manifest
    with_public(manifest: MANIFEST.except("theme_color")) do |root|
      Monk::Pwa.configure(root: root)

      refute_includes Monk::Context.new({}).monk_head.to_s, "theme-color"
    end
  end

  # --- serving ---

  def test_the_manifest_is_served_as_a_web_app_manifest
    with_assets("manifest.webmanifest" => JSON.generate(MANIFEST)) do
      _status, headers, = boot_app.call(env_for("GET", "/manifest.webmanifest"))

      assert_equal "application/manifest+json; charset=utf-8", headers["content-type"]
    end
  end

  # Linked without ?v= (its URL is its identity), so a deploy's new
  # sw.js must be revalidated, never cached for a year.
  def test_the_service_worker_is_revalidated_in_production
    with_assets("sw.js" => "self.addEventListener('install', () => {});\n") do
      _status, headers, = boot_app.call(env_for("GET", "/sw.js"))

      assert_equal "text/javascript; charset=utf-8", headers["content-type"]
      assert_equal "public, max-age=0, must-revalidate", headers["cache-control"]
    end
  end

  def test_the_register_script_is_served_from_the_gem
    with_assets({}) do
      status, headers, body = boot_app.call(env_for("GET", "/_monk/pwa/register.js"))

      assert_equal 200, status
      assert_equal "text/javascript; charset=utf-8", headers["content-type"]
      assert_includes body.join, %(register("/sw.js", { scope: "/", updateViaCache: "none" }))
    end
  end

  private

  # A public/ directory with a valid manifest and every file it links;
  # `files` overrides or (nil) removes one.
  def with_public(files = {}, manifest: MANIFEST, &)
    tree = {
      "manifest.webmanifest" => JSON.generate(manifest), "sw.js" => "// sw\n",
      "icons/icon-192.png" => "png", "icons/icon-512.png" => "png", "icons/apple-touch-icon.png" => "png",
    }.merge(files).compact
    with_tree("monk-pwa", tree, &)
  end

  def assert_invalid(root, message)
    error = assert_raises(Monk::Pwa::InvalidManifestError) { Monk::Pwa.configure(root: root) }
    assert_includes error.message, message
  end

  def boot_app
    app = Class.new(Monk::Base) { get("/") { "home" } }
    app.assets(Monk::Assets.root)
    boot_quietly(app)
    app
  end
end
