require_relative "freeze_hooks"
require_relative "persistence/pool"

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

      # Registered connection names (e.g. :primary) -- Monk.boot's log
      # line reads this to report which backends an app actually uses.
      def names
        configs.keys
      end

      def [](name)
        entry(name).conn
      end

      # With options, declares a named pool (docs/history/plan-pg-pool.md):
      # `size` worker Ractors, each with its own connection to the
      # registered database `db`, that run calls sent from any other
      # Ractor. Nothing connects until #start_pools! runs, in the process
      # that uses it. Every process loads the declarations
      # (config/persistence.rb), next to #register.
      #
      # Without options, returns the started pool, from any Ractor.
      # Raises if it was never declared, or declared but not started in
      # this process.
      def pool(name, **options)
        return declare_pool(name, **options) unless options.empty?

        pool_config(name)
        raise Monk::PoolNotStartedError,
          "pool #{name.inspect} is declared but not started in this process -- call " \
          "#{self}.start_pools!(#{name.inspect}) at boot in the process that uses it"
      end

      # A declared pool's options (a frozen Pool::Config).
      def pool_config(name)
        pools.fetch(name) do
          raise Monk::UnknownPoolError,
            "pool #{name.inspect} was never declared -- declare it once at boot with " \
            "#{self}.pool(#{name.inspect}, size: #{Pool::DEFAULTS[:size]}); " \
            "pool(#{name.inspect}) with no options only looks one up"
        end
      end

      def checkout(name, timeout: DEFAULT_CHECKOUT_TIMEOUT)
        e = entry(name)
        token = e.slot.pop(timeout: timeout)
        if token.nil?
          raise Monk::PersistenceTimeoutError,
            "timed out waiting for the #{name.inspect} connection " \
            "(checkout held longer than #{timeout}s)"
        end

        # Checked here, before the block, and never by re-running it: Monk
        # can't tell whether a failed block's writes reached the server,
        # so a drop in the middle of a block fails that block, and the
        # next checkout finds the connection dead and revives it. A
        # revive that can't reach the server raises from here.
        revive(e.conn) unless alive?(e.conn)
        yield e.conn
      ensure
        if token
          release(e.conn)
          e.slot << true
        end
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
        @pools = Ractor.make_shareable(pools)
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
        @pools = {}
      end

      private

      def configs
        @configs ||= {}
      end

      def pools
        @pools ||= {}
      end

      def declare_pool(name, **options)
        unknown = options.keys - Pool::DEFAULTS.keys
        raise ArgumentError, "unknown pool option(s) #{unknown.join(", ")} for #{name.inspect}" if unknown.any?
        raise ArgumentError, "pool #{name.inspect} is already declared" if pools.key?(name)

        config = Pool::Config.new(name: name, **Pool::DEFAULTS, **options)
        validate_pool!(config)
        pools[name] = Ractor.make_shareable(config)
      end

      def validate_pool!(config)
        unless configs.key?(config.db)
          raise Monk::UnknownPersistenceError,
            "pool #{config.name.inspect} uses db: #{config.db.inspect}, but no database is registered as " \
            "#{config.db.inspect} -- call #{self}.register(#{config.db.inspect}, ...) before declaring the pool"
        end

        { size: Integer, queue: Integer, timeout: Numeric }.each do |option, type|
          value = config.public_send(option)
          next if value.is_a?(type) && value.positive?

          raise ArgumentError,
            "pool #{config.name.inspect}: #{option}: must be a positive #{type}, got #{value.inspect}"
        end
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

      # Optional hooks around #checkout's block. A backend that can't tell
      # a dead connection from a live one keeps these defaults.

      # Whether conn can take a query. Cheap: runs before every checkout.
      def alive?(_conn) = true

      # Reconnects a connection #alive? said was dead; raises if it can't.
      def revive(_conn) = nil

      # Runs after every checkout's block, however it ended. Must not
      # raise: it runs in an ensure, and would hide the block's exception.
      def release(_conn) = nil
    end
  end
end
