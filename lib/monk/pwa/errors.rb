module Monk
  module Pwa
    # A manifest, an icon or the service worker that isn't there or isn't
    # what a browser needs to install the app, found by
    # Monk::Pwa.configure at boot.
    class InvalidManifestError < StandardError
    end
  end
end
