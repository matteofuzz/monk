require "pg"

module Monk
  # Owns per-Ractor Postgres connections: each Ractor lazily opens and
  # memoizes its own PG::Connection on first access, never shared across
  # Ractors (mirrors pg's own documented Ractor pattern). Concurrent access
  # from sibling threads within the same Ractor is serialized through
  # #checkout, since a bare PG::Connection isn't safe for two threads to
  # issue commands on at once.
  module Persistence
    DEFAULT_CHECKOUT_TIMEOUT = 5 # seconds

    Entry = Struct.new(:conn, :slot)

    class << self
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

      # Test-only: drops all registered configs and this Ractor's cached
      # connections. Not part of the app-facing API.
      def reset!
        Ractor.current[:monk_persistence]&.each_value do |e|
          e.conn.finish
        rescue PG::Error
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
            "Monk::Persistence.register(#{name.inspect}, ...) first"
        end

        conn = PG.connect(**opts)
        conn.type_map_for_results = PG::BasicTypeMapForResults.new(conn)

        slot = SizedQueue.new(1)
        slot << true

        Entry.new(conn, slot)
      end
    end
  end
end
