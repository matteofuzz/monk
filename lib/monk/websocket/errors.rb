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
  end
end
