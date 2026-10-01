require "redis"
require "securerandom"
require_relative "errors"
require_relative "listeners"

module Monk
  module WebSocket
    # Cross-process fan-out for Registry, opt-in: require
    # "monk/websocket/redis_fanout" explicitly -- "monk/websocket" alone
    # does not load this (docs/history/plan-websocket.md Phase 6, chosen over Postgres
    # LISTEN/NOTIFY per docs/design/websocket.md Open Question 3).
    #
    # Wraps a Registry with the same public interface (#register,
    # #unregister, #count, #broadcast, #listen!), so an app swaps which object it
    # holds and nothing else changes. #broadcast still delivers to this
    # process's local Registry directly -- same latency and reliability as
    # a plain Registry if Redis is briefly unavailable -- and additionally
    # publishes to Redis so sibling WS processes' subscriber Ractors
    # deliver it to their own local connections.
    #
    # Every published payload is tagged with this instance's origin id so
    # the subscriber ignores messages that are this process's own
    # broadcast echoed back over Redis -- without the tag, a broadcast
    # would reach local connections twice (once directly, once via the
    # round trip through Redis).
    #
    # #broadcast/#register keys must be Symbols. A Redis channel name is
    # always a String, so the subscriber has to pick one Ruby type to
    # convert the recovered channel back into -- Symbol, matching every
    # existing caller (Registry's own tests, the websocket_server
    # scaffold's :chat channel). A String-keyed #register(...) would still
    # get this process's own direct/local deliveries but never a relayed
    # one, since the relayed call always uses a Symbol.
    class RedisFanout
      # Frozen explicitly, not just left as a String literal -- the
      # subscriber Ractor below reads this constant from a non-main
      # Ractor, which raises Ractor::IsolationError unless its value is
      # already shareable.
      CHANNEL_PREFIX = "monk:ws:".freeze

      def initialize(registry, redis_url:)
        @registry = registry
        @redis_url = redis_url.dup.freeze
        @origin = SecureRandom.uuid.freeze

        # No live connection lives on this object -- #listen! runs its
        # subscriber in a Ractor of its own, and #publisher below opens one
        # client per Ractor, lazily -- so there's nothing left unshareable
        # and this instance can freeze itself the same way Registry does.
        # That matters for real use: an app holds this behind a module
        # constant (e.g. ChatServer::REGISTRY, mirroring Registry's own
        # existing usage) read from every connection's own Ractor, which
        # raises Ractor::IsolationError unless the constant's value is
        # shareable.
        freeze
      end

      # Starts relaying other processes' broadcasts into this process's
      # registry: a subscriber Ractor with its own Redis connection. Only
      # the process that holds sockets calls this (bin/websocket_server, at
      # boot, from the main Ractor) -- a publish-only process (bin/server,
      # bin/jobs) never does, so it holds no subscriber connection at all.
      # Returns once the psubscribe is in effect, so nothing broadcast
      # after it can be missed; raises ListenError if Redis can't be
      # reached. Calling it again is a no-op.
      def listen!
        return self if Listeners.listening?(@origin)

        ready = Ractor::Port.new
        # Ractor.new's block args must be shareable: registry is (Registry
        # freezes itself around a Ractor, which is inherently shareable),
        # the URL and origin are frozen Strings, a Port always is. The
        # Redis client itself is built inside the block, never passed in --
        # mirrors PG::Connection's per-Ractor pattern (persistence/pg.rb).
        Ractor.new(@registry, @redis_url, @origin, ready) do |registry, url, origin, ready|
          subscribed = false
          Redis.new(url: url).psubscribe("#{Monk::WebSocket::RedisFanout::CHANNEL_PREFIX}*") do |on|
            on.psubscribe do
              subscribed = true
              ready.send(:ok)
            end

            on.pmessage do |_pattern, channel, envelope|
              sender, payload = envelope.split("\0", 2)
              next if sender == origin

              # Redis channel names are always Strings, but Registry's own
              # keys are ordinary Hash keys the app chooses -- every
              # existing caller (Registry's own tests, the websocket_server
              # scaffold's :chat channel) uses a Symbol. #to_sym here is
              # what makes registry.broadcast(:chat, ...) land on the same
              # Hash key #register(:chat, port) used -- without it this
              # silently broadcasts to an unrelated "chat" String key that
              # nothing is ever registered under, and #broadcast still
              # returns true either way (Registry#broadcast succeeds
              # whether or not any port is registered for a key).
              key = channel.delete_prefix(Monk::WebSocket::RedisFanout::CHANNEL_PREFIX).to_sym
              registry.broadcast(key, payload)
            end
          end
        rescue StandardError => e
          raise if subscribed

          ready.send("#{e.class}: #{e.message}")
        end

        result = ready.receive
        raise ListenError, "Monk::WebSocket::RedisFanout#listen! couldn't subscribe: #{result}" unless result == :ok

        Listeners.add(@origin)
        self
      end

      def register(key, port)
        unless Listeners.listening?(@origin)
          raise NotListeningError,
            "Monk::WebSocket::RedisFanout#register before #listen!: this socket would never get " \
            "other processes' broadcasts -- call listen! once at boot in the process that holds " \
            "sockets (bin/websocket_server: Monk::Live.listen!)"
        end

        @registry.register(key, port)
      end

      def unregister(key, port) = @registry.unregister(key, port)
      def count(key) = @registry.count(key)

      def broadcast(key, payload)
        @registry.broadcast(key, payload)
        publisher.publish("#{CHANNEL_PREFIX}#{key}", "#{@origin}\0#{payload}")
      end

      private

      # A single shared Redis client called concurrently from every
      # connection Ractor's #broadcast wouldn't be safe -- redis-rb clients
      # aren't documented safe for concurrent commands from multiple
      # threads, let alone Ractors. One client per calling Ractor, opened
      # on first use and cached there, mirrors
      # Monk::Persistence::Registry's #ractor_local/#entry exactly.
      def publisher
        Ractor.current[:monk_redis_fanout_publisher] ||= Redis.new(url: @redis_url)
      end
    end
  end
end
