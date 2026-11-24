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

      # iOS's own Share and Add to Home Screen glyphs, for the sheet's
      # steps; currentColor, so they take the app's text colour.
      SHARE_ICON = '<svg class="monk-install__icon" viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" ' \
                   'fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" ' \
                   'stroke-linejoin="round">' \
                   '<path d="M12 3v12M7.5 7.5 12 3l4.5 4.5"/><path d="M8 10H6v11h12V10h-2"/></svg>'.freeze
      ADD_ICON = '<svg class="monk-install__icon" viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" ' \
                 'fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round">' \
                 '<rect x="3.5" y="3.5" width="17" height="17" rx="4"/><path d="M12 8v8M8 12h8"/></svg>'.freeze

      # A banner inviting people to install the app, for a layout or a page:
      #   <%= monk_install %>
      # Hidden until register.js shows it: on iOS, where its button opens
      # a sheet saying how to Add to Home Screen, or once the browser
      # offered its own prompt (Android's Chrome), which the button opens;
      # never in the installed app, nor on a desktop. BEM classes and no
      # styles: the app styles it. Every text can be overridden (another
      # language, say); the app's name is the manifest's.
      def monk_install(text: nil, button: "Install", share: "Tap Share", add: "then Add to Home Screen",
                       close: "OK")
        return raw("") unless Monk::Pwa.configured?

        text ||= "Install #{Monk::Pwa.manifest["name"]} on your device."
        raw(<<~HTML.chomp)
          <div class="monk-install" data-monk-install-banner hidden>
            <p class="monk-install__text">#{h(text)}</p>
            <button type="button" class="monk-install__button" data-monk-install>#{h(button)}</button>
            <dialog class="monk-install__sheet" data-monk-install-sheet>
              <ol class="monk-install__steps">
                <li class="monk-install__step">#{h(share)} #{SHARE_ICON}</li>
                <li class="monk-install__step">#{h(add)} #{ADD_ICON}</li>
              </ol>
              <form method="dialog"><button class="monk-install__close">#{h(close)}</button></form>
            </dialog>
          </div>
        HTML
      end
    end
  end
end
