require "securerandom"

module Monk
  module WebSocket
    # Cross-process fan-out for Registry, opt-in: require
    # "monk/websocket/pg_fanout" explicitly -- "monk/websocket" alone does
    # not load this. A second implementation of the exact interface
    # RedisFanout wraps a Registry behind (#register, #unregister, #count,
    # #broadcast, docs/design/live-pg-fanout.md,
    # docs/history/plan-live-pg-fanout.md), so an app swaps which object it
    # holds and nothing else changes. Uses Postgres LISTEN/NOTIFY instead
    # of Redis pub/sub -- for an app that already runs Postgres
    # (persistence, Monk::Auth) and doesn't need Redis's higher throughput
    # or its lack of a payload cap (see the design doc's "Where this is
    # worse than Redis").
    #
    # Phase 1 (docs/history/plan-live-pg-fanout.md): construction,
    # freeze, and plain delegation only. #broadcast's Postgres leg
    # (Phase 2) and the subscriber Ractor (Phase 3) land in later commits.
    class PgFanout
      def initialize(registry, pg_opts:)
        @registry = registry
        # Ractor.make_shareable, not a plain #freeze: pg_opts's values
        # (host/user/password Strings from ENV.fetch, typically) aren't
        # frozen individually just because the Hash itself is -- #freeze
        # only locks the Hash against further key/value changes, it
        # doesn't recurse. Without this, the shareability check below
        # fails on this Hash's contents, not on the registry argument it's
        # meant to guard, the same trap Server#initialize's
        # allowed_origins already avoids the same way.
        @pg_opts = Ractor.make_shareable(pg_opts.dup)
        # Frozen explicitly, not just a String literal: read from every
        # calling Ractor's own #broadcast (Phase 2) and from the
        # subscriber Ractor (Phase 3), both of which raise
        # Ractor::IsolationError on an unfrozen value -- same reason
        # RedisFanout freezes its own @origin.
        @origin = SecureRandom.uuid.freeze

        freeze

        # RedisFanout has no equivalent check -- freezing self never
        # raises on its own, even when an ivar (here, a caller-supplied
        # registry double) isn't itself shareable, so a bad registry
        # would otherwise only surface later as an opaque
        # Ractor::IsolationError the first time some other Ractor reads
        # this object. Checked explicitly, mirroring
        # Monk::Live.configure's own check of its registry argument.
        return if Ractor.shareable?(self)

        raise ArgumentError,
          "Monk::WebSocket::PgFanout.new needs a Ractor-shareable registry, got #{registry.class}"
      end

      def register(key, port) = @registry.register(key, port)
      def unregister(key, port) = @registry.unregister(key, port)
      def count(key) = @registry.count(key)
    end
  end
end
