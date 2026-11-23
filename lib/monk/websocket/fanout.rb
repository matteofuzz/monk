require_relative "errors"
require_relative "listeners"

module Monk
  module WebSocket
    # What PgFanout and RedisFanout share. Each wraps a Registry behind its
    # interface, so an app swaps which one it holds and nothing else
    # changes. Each defines .subscribe (its subscriber Ractor's body),
    # #subscriber_target (what that Ractor connects with, shareable) and
    # #broadcast.
    module Fanout
      # Starts relaying other processes' broadcasts into this process's
      # registry: a subscriber Ractor with its own connection. Only the
      # process that holds sockets calls this (bin/websocket_server, at
      # boot, from the main Ractor); a publish-only process (bin/server,
      # bin/jobs) never does, so it holds no subscriber connection at all.
      # Returns once the subscription is in effect, so nothing broadcast
      # after it can be missed; raises ListenError if it can't connect.
      # Calling it again is a no-op.
      def listen!
        return self if Listeners.listening?(@origin)

        ready = Ractor::Port.new
        # Ractor.new's arguments must be shareable: the class, the registry
        # (it freezes itself), the frozen target and origin, a Port. The
        # connection is opened inside the Ractor, never passed in.
        Ractor.new(self.class, @registry, subscriber_target, @origin, ready) do |fanout, registry, target, origin, port|
          fanout.subscribe(registry, target, origin, port)
        end

        result = ready.receive
        raise ListenError, "#{self.class.name}#listen! couldn't subscribe: #{result}" unless result == :ok

        Listeners.add(@origin)
        self
      end

      def register(key, port)
        ensure_listening!(:register)
        @registry.register(key, port)
      end

      def register_many(keys, port)
        ensure_listening!(:register_many)
        @registry.register_many(keys, port)
      end

      def unregister(key, port) = @registry.unregister(key, port)
      def unregister_many(keys, port) = @registry.unregister_many(keys, port)
      def count(key) = @registry.count(key)

      private

      def ensure_listening!(method)
        return if Listeners.listening?(@origin)

        raise NotListeningError,
          "#{self.class.name}##{method} before #listen!: this socket would never get " \
          "other processes' broadcasts -- call listen! once at boot in the process that holds " \
          "sockets (bin/websocket_server: Monk::Live.listen!)"
      end
    end
  end
end
