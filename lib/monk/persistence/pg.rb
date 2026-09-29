require "json"
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

      # json/jsonb columns, decoded with plain JSON.parse. pg's own
      # PG::TextDecoder::JSON (1.6.3) calls JSON.parse(string, quirks_mode:
      # true), and json 3 removed that keyword, so with pg's default every
      # json/jsonb read raised ArgumentError. json 3 parses a bare scalar
      # ("7", "\"text\"") without it.
      class JsonDecoder < PG::SimpleDecoder
        def decode(string, _tuple = nil, _field = nil)
          JSON.parse(string)
        end
      end

      # pg's default result types, with JsonDecoder for json and jsonb.
      # Built once and made shareable, so every Ractor's #connect can use
      # it rather than building its own.
      RESULT_TYPES = Ractor.make_shareable(
        PG::BasicTypeRegistry.new.register_default_types
          .tap { |types| %w[json jsonb].each { |name| types.register_type(0, name, nil, JsonDecoder) } },
      )

      class << self
        private

        def connect(**opts)
          conn = PG.connect(**opts)
          conn.type_map_for_results = PG::BasicTypeMapForResults.new(conn, registry: RESULT_TYPES)
          conn
        end

        def disconnect(conn)
          conn.finish
        end
      end
    end
  end
end
