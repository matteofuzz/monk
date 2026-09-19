require_relative "../monk"
require_relative "live/errors"
require_relative "live/renderer"
require_relative "live/envelope"
require_relative "live/publisher"

# Opt-in, like Monk::WebSocket and Monk::Auth: require "monk/live"
# explicitly. `require "monk"` alone must not load this (ADR 0008).
module Monk
  module Live
    # Eager, never `@x ||=`: a lazy reader writes on first access, which is
    # an isolation error from a non-main Ractor (same rule as Monk::Views).
    @publisher = nil

    class << self
      attr_reader :publisher

      # Boot-time, main Ractor. `registry` is a Monk::WebSocket::Registry,
      # or a RedisFanout wrapping one when publishing has to reach WS
      # connections in another process. It must be Ractor-shareable (both
      # are), since request workers read the publisher from their own
      # Ractors -- checked here, at boot, rather than on a live request.
      def configure(registry:)
        publisher = Publisher.new(registry)
        unless Ractor.shareable?(publisher)
          raise ArgumentError,
            "Monk::Live.configure(registry:) needs a Ractor-shareable registry, got #{registry.class}"
        end

        @publisher = publisher
      end

      # Test-only, like Monk::Views.reset!.
      def reset!
        @publisher = nil
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
