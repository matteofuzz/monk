# An installable app (Monk::Pwa): the web app manifest, its icons and the
# service worker, all the app's own files in public/, checked at boot.
Monk::Generator.define(:pwa) do
  summary "Installable app: web app manifest, icons, service worker"
  installed_if "config/pwa.rb"

  copy "config/pwa.rb", "public/sw.js", role: :wiring
  copy "public/manifest.webmanifest", role: :wiring, app_name: true
  # Skipped, not a conflict, when the app already has its own.
  copy "public/icons/icon-192.png", "public/icons/icon-512.png", "public/icons/icon-maskable-512.png",
    "public/icons/apple-touch-icon.png", role: :view
  copy "test/pwa_test.rb", role: :test

  setup_section "pwa/setup.md"
  agents_section "pwa/agents.md"
  closing "Then set the name people see in public/manifest.webmanifest (name, short_name), " \
          "and replace the placeholder icons in public/icons/."
end
