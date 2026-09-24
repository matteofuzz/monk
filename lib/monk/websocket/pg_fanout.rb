require "pg"
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
    # Phase 3 (docs/history/plan-live-pg-fanout.md) adds the subscriber
    # Ractor that makes this actually cross-process; through Phase 2,
    # #broadcast only ever has itself to echo back to.
    class PgFanout
      # Postgres has no pattern LISTEN (unlike Redis's own
      # psubscribe("monk:ws:*")), so every key shares one fixed channel;
      # the key rides inside the notification payload instead of the
      # channel name -- see Phase 3's subscriber for the other half of
      # this.
      CHANNEL = "monk_live".freeze

      # Postgres's own hard limit on a single NOTIFY payload -- verified
      # directly against a real server (not assumed from documentation):
      # 7999 bytes succeeds, exactly 8000 fails with "payload string too
      # long". #broadcast checks the full envelope (origin + key + app
      # payload) against this *exclusive* bound before ever calling
      # pg_notify, so an oversized broadcast fails with a clear
      # PayloadTooLargeError instead of a raw PG::Error surfacing from
      # inside the query.
      MAX_NOTIFY_PAYLOAD_BYTES = 8000

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

      def broadcast(key, payload)
        # Delivers locally first, regardless of what happens next -- same
        # latency and reliability as a plain Registry if Postgres is
        # briefly unavailable or this payload is over the wire cap,
        # mirroring RedisFanout#broadcast's own ordering.
        @registry.broadcast(key, payload)

        envelope = envelope_for(key, payload)
        if envelope.bytesize >= MAX_NOTIFY_PAYLOAD_BYTES
          raise Monk::WebSocket::PayloadTooLargeError,
            "Monk::WebSocket::PgFanout#broadcast payload plus origin/key framing is " \
            "#{envelope.bytesize} bytes; Postgres NOTIFY accepts a payload of at most " \
            "#{MAX_NOTIFY_PAYLOAD_BYTES - 1} bytes -- shrink the fragment, or use " \
            "Monk::WebSocket::RedisFanout instead, which has no such cap"
        end

        # pg_notify(channel, payload), not a string-built
        # "NOTIFY channel, 'payload'" -- passing the envelope as a bound
        # parameter sidesteps any quoting/injection concern for its bytes
        # entirely, unlike Redis's PUBLISH, which never had that concern
        # in the first place.
        publisher.exec_params("SELECT pg_notify($1, $2)", [CHANNEL, envelope])
      end

      private

      # Length-prefixes the origin and key (Netstring-style: "<bytesize>:"
      # then that many bytes) instead of RedisFanout's NUL-separated
      # "origin\0payload" -- discovered while building this that a NUL
      # byte can't ride in a Postgres NOTIFY payload at all (a bound text
      # parameter containing one raises "string contains null byte" from
      # inside exec_params; text NOTIFY payloads simply don't carry one).
      # A digit run followed by ':' can never be confused with content
      # coming later: the header is always the *first* ':' in the whole
      # string, no matter what colons, NULs or anything else an app's key
      # or payload contains.
      #
      # Forces binary (.b) throughout so slicing by the recorded byte
      # lengths lines up exactly -- the same fix Monk::WebSocket::Frame.encode
      # needed for non-ASCII payloads (docs/history/plan-live.md Phase 7);
      # a String#[] by character count on a UTF-8 string would misalign
      # the moment origin/key/payload aren't pure ASCII.
      def envelope_for(key, payload)
        origin_bytes = @origin.b
        key_bytes = key.to_s.b
        "#{origin_bytes.bytesize}:".b + origin_bytes + "#{key_bytes.bytesize}:".b + key_bytes + payload.to_s.b
      end

      # One PG::Connection per calling Ractor, opened on first use and
      # cached there -- a single client called concurrently from every
      # connection Ractor's #broadcast wouldn't be safe, mirrors
      # RedisFanout#publisher and Monk::Persistence::Pg's own per-Ractor
      # pattern exactly. Never the connection Monk::Persistence::Pg hands
      # out for app queries: NOTIFY issued on a connection mid-transaction
      # wouldn't fire until that transaction commits, so this stays a
      # connection of its own, used for nothing but one-off notifies.
      def publisher
        Ractor.current[:monk_pg_fanout_publisher] ||= PG.connect(**@pg_opts)
      end
    end
  end
end
