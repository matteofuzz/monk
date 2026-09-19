require_relative "../monk"
require_relative "live/errors"
require_relative "live/renderer"
require_relative "live/envelope"
require_relative "live/publisher"
require_relative "live/policy"
require_relative "live/session"
require_relative "live/helpers"

# Opt-in, like Monk::WebSocket and Monk::Auth: require "monk/live"
# explicitly. `require "monk"` alone must not load this (ADR 0008).
module Monk
  Context.include(Live::Helpers)

  module Live
    # Eager, never `@x ||=`: a lazy reader writes on first access, which is
    # an isolation error from a non-main Ractor (same rule as Monk::Views).
    @publisher = nil
    @registry = nil
    @rules = [].freeze
    @max_topics = 100

    # Handed to Monk::WebSocket::Server#run in a WS process:
    #   server.run(&Monk::Live::HANDLER)
    # Built here, in the module body, where self is shareable, as the
    # server requires.
    HANDLER = proc do |connection|
      registry = Monk::Live.registry || raise(Monk::Live::NotConfiguredError,
        "Monk::Live isn't configured -- call Monk::Live.configure(registry: ...) at boot",)
      Monk::Live::Session.new(
        connection, registry: registry, rules: Monk::Live.rules, max_topics: Monk::Live.max_topics,
      ).run
    end

    CLIENT_DIR = File.expand_path("live/client", __dir__).freeze

    class << self
      attr_reader :publisher, :registry, :rules, :max_topics

      # Where the browser runtime ships inside the gem: monk_live.js,
      # protocol.js and idiomorph.js (they import each other by relative
      # path, so an app serves or copies the directory as a unit).
      def client_dir = CLIENT_DIR

      # Boot-time, main Ractor. `registry` is a Monk::WebSocket::Registry,
      # or a RedisFanout wrapping one when publishing has to reach WS
      # connections in another process. It must be Ractor-shareable (both
      # are), since request workers read the publisher from their own
      # Ractors -- checked here, at boot, rather than on a live request.
      def configure(registry:, max_topics: 100)
        publisher = Publisher.new(registry)
        unless Ractor.shareable?(publisher)
          raise ArgumentError,
            "Monk::Live.configure(registry:) needs a Ractor-shareable registry, got #{registry.class}"
        end

        @publisher = publisher
        @registry = registry
        @max_topics = max_topics
      end

      # Boot-time, main Ractor. See Monk::Live::Policy for the semantics:
      # deny by default, first matching rule wins, anonymous subjects need
      # `anonymous: true`. The block must be Ractor-shareable.
      def authorize(pattern, anonymous: false, &block)
        @rules = Ractor.make_shareable([*@rules, Policy.build_rule(pattern, anonymous, block)])
      end

      def authorized?(subject, topic) = Policy.allowed?(rules, subject, topic)

      # Test-only, like Monk::Views.reset!.
      def reset!
        @publisher = nil
        @registry = nil
        @rules = [].freeze
        @max_topics = 100
      end

      def patch(topic, **) = current.patch(topic, **)
      def append(topic, **) = current.append(topic, **)
      def prepend(topic, **) = current.prepend(topic, **)
      def remove(topic, **) = current.remove(topic, **)
      def batch(topic, &) = current.batch(topic, &)

      private

      def current
        publisher || raise(Monk::Live::NotConfiguredError,
          "Monk::Live isn't configured -- call Monk::Live.configure(registry: ...) at boot",)
      end
    end
  end
end
