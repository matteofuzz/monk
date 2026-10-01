module Monk
  module WebSocket
    class HandshakeError < StandardError
    end

    class ProtocolError < StandardError
    end

    # Raised by PgFanout#broadcast before ever calling pg_notify, rather
    # than letting a raw PG::Error surface from inside it or silently
    # truncating -- see docs/design/live-pg-fanout.md's payload-cap
    # tradeoff.
    class PayloadTooLargeError < StandardError
    end

    # A fanout's #register before its #listen!: a socket registered there
    # would never get another process's broadcasts, so this says so at the
    # first subscription instead of losing them silently.
    class NotListeningError < StandardError
    end

    # #listen! couldn't open its subscriber connection (Redis or Postgres
    # unreachable, bad credentials) -- raised in the WS process's boot.
    class ListenError < StandardError
    end
  end
end
