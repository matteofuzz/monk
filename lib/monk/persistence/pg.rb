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

      # Without a connect_timeout, libpq waits indefinitely for a host that
      # doesn't answer -- and #checkout's revive does so holding the
      # Ractor's slot. The same 5 s as Registry's checkout timeout. An
      # app's own connect_timeout: wins.
      DEFAULT_CONNECT_TIMEOUT = 5

      # Every diagnostic field libpq reports for an error (SQLSTATE,
      # constraint, table, detail, hint, ...).
      DIAG_FIELDS = PG.constants.grep(/\APG_DIAG_/).map { |name| PG.const_get(name) }.freeze

      # What a PG::Error's #result becomes when the error leaves a pool's
      # worker (#make_portable): a PG::Result is tied to its connection and
      # can't be copied to another Ractor. Keeps what reading an error
      # needs; anything else raises NoMethodError.
      ErrorResult = Data.define(:fields, :error_message, :result_status, :res_status) do
        def self.from(result)
          fields = DIAG_FIELDS.to_h { |code| [code, result.error_field(code)] }.compact
          new(
            fields: fields, error_message: result.error_message,
            result_status: result.result_status, res_status: result.res_status,
          )
        end

        def error_field(code) = fields[code]
        alias_method :result_error_field, :error_field
        alias_method :result_error_message, :error_message
      end

      class << self
        # A copy of an exception about to leave a pool's worker
        # (Pool::Portable): a PG::Error holds its connection and result,
        # which can't be copied to another Ractor. The connection goes (no
        # use in another Ractor anyway), and the result becomes an
        # ErrorResult, so error_field still answers. The error keeps its
        # class, so `rescue PG::UniqueViolation` matches as it would here.
        def make_portable(error)
          return unless error.is_a?(PG::Error)

          result = error.result
          error.instance_variable_set(:@connection, nil)
          error.instance_variable_set(:@result, result && ErrorResult.from(result))
        end

        # Detects a connection the server has closed (a restart, a
        # failover, pg_terminate_backend). libpq still reports
        # CONNECTION_OK, but the socket is readable: a healthy idle
        # connection's isn't. So the common case costs one zero-timeout
        # select, about 1 µs, and nothing sent.
        #
        # A readable socket is either the server's FATAL before it closes,
        # or a NOTIFY on a connection that LISTENs. Reading on to tell
        # them apart races the close: the FATAL can arrive a moment before
        # the end of file, and a second select in between sees nothing.
        # So a readable socket gets an empty query, one round trip, which
        # fails on a closed connection and leaves pending notifies queued.
        #
        # A network path that dies without closing the socket (a NAT
        # timing out an idle connection) leaves it unreadable, and this
        # can't see it: the next query waits for TCP to give up.
        #
        # Public: PgFanout probes its own connections with it.
        def alive?(conn)
          return false unless conn.status == PG::CONNECTION_OK
          return true unless conn.socket_io.wait_readable(0)

          conn.exec("")
          true
        rescue PG::Error, IOError
          false
        end

        # Same connection object, new backend: the result type map set by
        # #connect survives. Raises PG::ConnectionBad if Postgres is still
        # unreachable; the next checkout tries again.
        def revive(conn)
          conn.reset
        end

        private

        # A block that ran a raw BEGIN and raised leaves the connection in
        # a transaction, and the next checkout in this Ractor would run
        # inside it. (conn.transaction rolls back by itself.) Skipped for
        # PQTRANS_ACTIVE, a query still running: a ROLLBACK would first
        # wait for it. Monk::Jobs cancels those itself.
        def release(conn)
          return unless conn.status == PG::CONNECTION_OK
          return unless [PG::PQTRANS_INTRANS, PG::PQTRANS_INERROR].include?(conn.transaction_status)

          conn.exec("ROLLBACK")
        rescue PG::Error
          nil
        end

        def connect(**opts)
          conn = PG.connect(connect_timeout: DEFAULT_CONNECT_TIMEOUT, **opts)
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
