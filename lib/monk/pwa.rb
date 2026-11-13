require_relative "../monk"
require_relative "pwa/errors"
require_relative "pwa/manifest"
require_relative "pwa/helpers"

# Opt-in: require "monk/pwa" explicitly; `require "monk"` alone doesn't
# load it. Makes the app installable (docs/plan-pwa-push.md, part A): the
# app's own public/manifest.webmanifest, icons and public/sw.js, checked
# at boot and linked from every page by <%= monk_head %>.
module Monk
  Context.include(Pwa::Helpers)

  module Pwa
    MANIFEST_PATH = "/manifest.webmanifest".freeze
    # At the root, so its scope is the whole site: a service worker can
    # only control pages under its own path.
    SERVICE_WORKER_PATH = "/sw.js".freeze
    APPLE_TOUCH_ICON = "/icons/apple-touch-icon.png".freeze

    CLIENT_DIR = File.expand_path("pwa/client", __dir__).freeze
    # register.js, served from the gem like Live's client.
    CLIENT_PATH = "/_monk/pwa".freeze
    Monk::Assets.mount(CLIENT_PATH, CLIENT_DIR)

    # Eager, never `@x ||=` (a lazy write from a worker Ractor is an
    # isolation error).
    @manifest = nil
    @apple_touch_icon = nil

    class << self
      # The parsed manifest, frozen; nil until configured.
      attr_reader :manifest, :apple_touch_icon

      # Boot-time, main Ractor, from config/pwa.rb. Reads and checks the
      # manifest under the app's public/ (Monk::Assets.root), the icons it
      # names, the service worker and the apple-touch-icon: anything
      # missing or not installable raises InvalidManifestError here.
      def configure(apple_touch_icon: APPLE_TOUCH_ICON, root: Monk::Assets.root)
        raise ArgumentError, "Monk::Pwa needs Monk to serve public/ (the app has `assets false`)" unless root

        @manifest = Manifest.check!(root, MANIFEST_PATH.delete_prefix("/"), [SERVICE_WORKER_PATH, apple_touch_icon])
        @apple_touch_icon = apple_touch_icon.dup.freeze
      end

      def configured? = !@manifest.nil?

      # Test-only.
      def reset!
        @manifest = nil
        @apple_touch_icon = nil
      end
    end
  end
end
