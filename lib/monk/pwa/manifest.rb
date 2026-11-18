require "json"

module Monk
  module Pwa
    # The boot-time check of public/manifest.webmanifest and the files it
    # names: what Chrome asks of an installable app, plus the files Monk's
    # head tags link. A mistake fails the boot naming the file, instead of
    # an app that silently can't be installed.
    module Manifest
      # A display mode that opens the app in its own window; "browser"
      # (the default when unset) isn't installable.
      DISPLAYS = %w[standalone fullscreen minimal-ui].freeze
      # Chrome needs a 192 and a 512 icon whose purpose includes "any".
      REQUIRED_SIZES = %w[192x192 512x512].freeze
      PLACEHOLDER = "{{app}}".freeze

      module_function

      # The parsed manifest, frozen, or InvalidManifestError. files are
      # the public paths Monk links besides the manifest (the service
      # worker, the apple-touch-icon); each must be a file under root.
      def check!(root, path, files)
        manifest = parse(root, path)
        fail!(path, "needs a name and a short_name") unless text?(manifest["name"]) && text?(manifest["short_name"])
        if [manifest["name"], manifest["short_name"]].any? { |value| value.include?(PLACEHOLDER) }
          fail!(path, "still has #{PLACEHOLDER} in name or short_name: set the app's name")
        end
        fail!(path, "needs a start_url") unless text?(manifest["start_url"])
        unless DISPLAYS.include?(manifest["display"])
          fail!(path, "needs display: one of #{DISPLAYS.join(", ")} (got #{manifest["display"].inspect})")
        end

        check_icons!(root, path, manifest["icons"])
        files.each { |file| fail!(path, "links #{file}, which isn't in #{root}/") unless served?(root, file) }
        Ractor.make_shareable(manifest)
      end

      def parse(root, path)
        full = File.join(root, path)
        fail!(path, "isn't in #{root}/") unless File.file?(full)

        manifest = JSON.parse(File.read(full))
        fail!(path, "must be a JSON object") unless manifest.is_a?(Hash)

        manifest
      rescue JSON::ParserError => e
        fail!(path, "isn't valid JSON: #{e.message.lines.first.strip}")
      end

      def check_icons!(root, path, icons)
        fail!(path, "needs an icons list") unless icons.is_a?(Array) && icons.all?(Hash)

        any = icons.select { |icon| (icon["purpose"] || "any").split.include?("any") }
        REQUIRED_SIZES.each do |size|
          next if any.any? { |icon| icon["sizes"].to_s.split.include?(size) }

          fail!(path, "needs a #{size} icon (purpose any)")
        end
        icons.each do |icon|
          src = icon["src"]
          fail!(path, "has an icon without a src") unless text?(src)
          fail!(path, "names icon #{src}, which isn't in #{root}/") if src.start_with?("/") && !served?(root, src)
        end
      end

      def served?(root, public_path) = File.file?(File.join(root, public_path.delete_prefix("/")))
      def text?(value) = value.is_a?(String) && !value.strip.empty?

      def fail!(path, message)
        raise InvalidManifestError, "#{path} #{message}"
      end
    end
  end
end
