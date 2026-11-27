require_relative "test_helper"
require "json"
require "monk/pwa"

# Monk::Pwa (docs/history/plan-pwa-push.md, part A): configure checks the app's
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
    with_public({ "offline.html" => nil }) { |root| assert_invalid(root, "links /offline.html") }
    with_public({ "icons/apple-touch-icon.png" => nil }) do |root|
      assert_invalid(root, "links /icons/apple-touch-icon.png")
    end
  end

  def test_an_icon_on_another_origin_is_not_looked_for
    remote_icon = { "src" => "https://cdn.example/i.png", "sizes" => "48x48" }
    remote = MANIFEST.merge("icons" => MANIFEST["icons"] + [remote_icon])
    with_public(manifest: remote) { |root| Monk::Pwa.configure(root: root) }

    assert_includes Monk::Pwa.manifest["icons"], remote_icon
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
      assert_match(%r{<script type="module" src="/_monk/pwa/offline\.js(\?v=\h+)?"></script>}, head)
    end
  end

  def test_no_theme_colour_meta_without_one_in_the_manifest
    with_public(manifest: MANIFEST.except("theme_color")) do |root|
      Monk::Pwa.configure(root: root)

      refute_includes Monk::Context.new({}).monk_head.to_s, "theme-color"
    end
  end

  # --- monk_install ---

  # Hidden until register.js shows it (iOS, or once installable), with BEM
  # classes and no styles: the app styles it.
  def test_monk_install_renders_a_hidden_banner_its_button_and_the_ios_sheet
    with_public do |root|
      Monk::Pwa.configure(root: root)
      html = Monk::Context.new({}).monk_install.to_s

      assert_match(/\A<div class="monk-install" data-monk-install-banner hidden>/, html)
      assert_includes html, %(<p class="monk-install__text">Install Shop on your device.</p>)
      assert_includes html, %(<button type="button" class="monk-install__button" data-monk-install>Install</button>)
      assert_includes html, %(<dialog class="monk-install__sheet" data-monk-install-sheet>)
      assert_includes html, "Add to Home Screen"
      assert_equal 2, html.scan("<svg").size, "the Share and Add to Home Screen icons"
      assert_includes html, %(<form method="dialog"><button class="monk-install__close">OK</button></form>)
      refute_includes html, "style="
    end
  end

  def test_monk_install_text_is_overridable_and_escaped
    with_public do |root|
      Monk::Pwa.configure(root: root)
      html = Monk::Context.new({}).monk_install(
        text: "Installa <Shop>", button: "Installa", share: "Tocca Condividi", add: "poi Aggiungi a Home",
        close: "Chiudi",
      ).to_s

      assert_includes html, "Installa &lt;Shop&gt;"
      assert_includes html, ">Installa</button>"
      assert_includes html, "Tocca Condividi"
      assert_includes html, "poi Aggiungi a Home"
      assert_includes html, ">Chiudi</button>"
    end
  end

  # Rendered in the server's worker Ractors.
  def test_monk_install_icons_are_shareable
    assert Ractor.shareable?(Monk::Pwa::Helpers::SHARE_ICON)
    assert Ractor.shareable?(Monk::Pwa::Helpers::ADD_ICON)
  end

  def test_monk_install_is_empty_until_configured
    assert_equal "", Monk::Context.new({}).monk_install.to_s
  end

  # --- monk_offline ---

  # Hidden until offline.js shows it, with the text for the reason.
  def test_monk_offline_renders_a_hidden_banner_with_a_text_per_reason
    with_public do |root|
      Monk::Pwa.configure(root: root)
      html = Monk::Context.new({}).monk_offline.to_s

      assert_match(/\A<div class="monk-offline" data-monk-offline-banner role="status" hidden>/, html)
      assert_includes html,
        %(<p class="monk-offline__text" data-monk-offline-reason="network" hidden>You’re offline.</p>)
      assert_includes html, %(data-monk-offline-reason="server" hidden>Can’t reach the server, retrying…</p>)
      assert_includes html, %(data-monk-offline-reason="unreachable" hidden>Can’t connect.</p>)
      refute_includes html, "style="
    end
  end

  def test_monk_offline_texts_are_overridable_and_escaped
    with_public do |root|
      Monk::Pwa.configure(root: root)
      html = Monk::Context.new({}).monk_offline(network: "Sei <offline>", server: "Server giù",
        unreachable: "Niente",).to_s

      assert_includes html, ">Sei &lt;offline&gt;</p>"
      assert_includes html, ">Server giù</p>"
      assert_includes html, ">Niente</p>"
    end
  end

  def test_monk_offline_is_empty_until_configured
    assert_equal "", Monk::Context.new({}).monk_offline.to_s
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
      "manifest.webmanifest" => JSON.generate(manifest), "sw.js" => "// sw\n", "offline.html" => "<p>offline</p>",
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
