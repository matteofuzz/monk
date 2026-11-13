require "monk"
require "monk/pwa"

# The app is installable (monk add pwa): public/manifest.webmanifest, the
# icons in public/icons/ and the service worker public/sw.js. Loaded by
# config/load.rb. configure reads the manifest and fails the boot if it, an
# icon it names or sw.js is missing, or if a browser couldn't install the
# app from it; the layout's <%= monk_head %> then links them on every page.
Monk::Pwa.configure
