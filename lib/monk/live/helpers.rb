module Monk
  module Live
    # View helpers, mixed into Monk::Context when "monk/live" is required
    # (before Boot, like any other Context method).
    module Helpers
      # The attribute the client runtime subscribes from:
      #   <ul id="contacts" <%= live_topic "contacts:#{current_user.id}" %>>
      # Refuses, at render time, a topic the server would refuse at
      # subscribe time (Session::TOPIC_FORMAT), so the mistake shows up in
      # the developer's page instead of as a silent denial in production.
      def live_topic(*topics)
        raise ArgumentError, "live_topic needs at least one topic" if topics.empty?

        names = topics.map(&:to_s)
        bad = names.grep_v(Session::TOPIC_FORMAT)
        raise ArgumentError, "invalid live topic(s): #{bad.inspect}" unless bad.empty?

        raw(%(data-live-topic="#{names.join(" ")}"))
      end

      # For the layout's <%= monk_head %>: where the client opens its
      # WebSocket (live_ws_url, which config/live.rb declares) and the
      # client runtime itself. Nothing until Live is configured, i.e. until
      # config/live.rb has run.
      def head_tags
        return super unless Monk::Live.registry

        super + [
          %(<meta name="monk-live-url" content="#{h(settings[:live_ws_url])}">),
          %(<script type="module" src="#{h(asset_path("#{Live::CLIENT_PATH}/monk_live.js"))}"></script>),
        ]
      end
    end
  end
end
