module Monk
  module Push
    # Mixed into Monk::Context when "monk/push" is required, before Boot.
    module Helpers
      # For the layout's <%= monk_head %>: the VAPID public key the browser
      # subscribes with, where the page stores its subscription (the app's
      # route, configure's path:), and Monk's push.js. Nothing until
      # config/push.rb has called Monk::Push.configure.
      def head_tags
        return super unless Monk::Push.configured?

        super + [
          %(<meta name="monk-push-key" content="#{h(Monk::Push.public_key)}">),
          %(<meta name="monk-push-url" content="#{h(Monk::Push.config[:path])}">),
          %(<script type="module" src="#{h(asset_path("#{Push::CLIENT_PATH}/push.js"))}"></script>),
        ]
      end
    end
  end
end
