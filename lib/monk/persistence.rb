require_relative "freeze_hooks"

module Monk
  # Backend-agnostic persistence. Concrete backends (e.g.
  # Monk::Persistence::Pg, loaded separately -- persistence backends are
  # opt-in, not required by `require "monk"`) extend Registry below and
  # register themselves into Monk.freeze_hooks automatically, so Base#freeze!
  # can seal every backend actually in use without needing to know their
  # names.
  module Persistence
    # Shared by every backend module: per-Ractor connection lifecycle, a
    # registry of named configs, and boot-time shareability sealing. A
    # backend `extend`s this and implements #connect(**opts) /
    # #disconnect(conn) (both private); registration, lookup, serialized
    # checkout, and freezing are identical across backends and live here
    # once.
    module Registry
      DEFAULT_CHECKOUT_TIMEOUT = 5 # seconds

      Entry = Struct.new(:conn, :slot)

      def self.extended(base)
        Monk.freeze_hooks << base
      end

      def register(name, **opts)
        configs[name] = opts
      end

      def [](name)
        entry(name).conn
      end

      def checkout(name, timeout: DEFAULT_CHECKOUT_TIMEOUT)
        e = entry(name)
        token = e.slot.pop(timeout: timeout)
        if token.nil?
          raise Monk::PersistenceTimeoutError,
            "timed out waiting for the #{name.inspect} connection " \
            "(checkout held longer than #{timeout}s)"
        end

        yield e.conn
      ensure
        e.slot << true if token
      end

      # Called from Base#freeze! (Seam B), via Monk.freeze_hooks.
      # Without this, #register'd configs are unreachable from any worker
      # Ractor at all: @configs is a plain, unfrozen Hash, and reading an
      # unfrozen value from a class/module instance variable raises
      # Ractor::IsolationError from any non-main Ractor -- the same
      # restriction Model.freeze_all! exists for, just on the
      # connect-options registry instead of a Model's own config. Freezing
      # the value (not the module) fixes it, the same way it did there.
      def freeze_registry!
        @configs = Ractor.make_shareable(configs)
      end

      # Test-only: drops all registered configs and this Ractor's cached
      # connections. Not part of the app-facing API.
      def reset!
        Ractor.current[:monk_persistence]&.each_value do |e|
          disconnect(e.conn)
        rescue StandardError
        end
        Ractor.current[:monk_persistence] = {}
        @configs = {}
      end

      private

      def configs
        @configs ||= {}
      end

      def ractor_local
        Ractor.current[:monk_persistence] ||= {}
      end

      def entry(name)
        ractor_local[name] ||= build_entry(name)
      end

      def build_entry(name)
        opts = configs.fetch(name) do
          raise Monk::UnknownPersistenceError,
            "no database registered as #{name.inspect} -- call " \
            "#{self}.register(#{name.inspect}, ...) first"
        end

        slot = SizedQueue.new(1)
        slot << true

        Entry.new(connect(**opts), slot)
      end

      def connect(**opts)
        raise NotImplementedError, "#{self} must implement #connect(**opts)"
      end

      def disconnect(conn)
        raise NotImplementedError, "#{self} must implement #disconnect(conn)"
      end
    end
  end
end
