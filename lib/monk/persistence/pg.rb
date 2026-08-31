require "pg"

require_relative "../persistence"

module Monk
  module Persistence
    # Postgres backend. Opt-in: require "monk/persistence/pg" explicitly --
    # `require "monk"` alone does not load this. Each Ractor lazily opens
    # and memoizes its own PG::Connection on first access, never shared
    # across Ractors (mirrors pg's own documented Ractor pattern --
    # PG::Connection is explicitly not shareable and must be created fresh
    # per Ractor). Concurrent access from sibling threads within the same
    # Ractor is serialized through #checkout (from Registry), since a bare
    # PG::Connection isn't safe for two threads to issue commands on at
    # once.
    module Pg
      extend Monk::Persistence::Registry

      class << self
        private

        def connect(**opts)
          conn = PG.connect(**opts)
          conn.type_map_for_results = PG::BasicTypeMapForResults.new(conn)
          conn
        end

        def disconnect(conn)
          conn.finish
        end
      end
    end
  end
end
