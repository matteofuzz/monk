module Monk
  module Pwa
    # Mixed into Monk::Context when "monk/pwa" is required, before Boot.
    module Helpers
      # For the layout's <%= monk_head %>: the manifest, the theme colour,
      # the Home Screen icon iOS uses, and Monk's script that registers
      # /sw.js. Nothing until config/pwa.rb has called Monk::Pwa.configure.
      #
      # The manifest and the service worker are linked by their plain
      # paths, never asset_path's ?v=: a service worker's URL is its
      # identity, so a new one each deploy would be a new registration.
      def head_tags
        return super unless Monk::Pwa.configured?

        theme_color = Monk::Pwa.manifest["theme_color"]
        super + [
          %(<link rel="manifest" href="#{h(Pwa::MANIFEST_PATH)}">),
          (%(<meta name="theme-color" content="#{h(theme_color)}">) if theme_color.is_a?(String)),
          %(<link rel="apple-touch-icon" href="#{h(asset_path(Monk::Pwa.apple_touch_icon))}">),
          %(<script type="module" src="#{h(asset_path("#{Pwa::CLIENT_PATH}/register.js"))}"></script>),
        ].compact
      end
    end
  end
end
