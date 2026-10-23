module Monk
  module WebSocket
    # Which fanouts in this process have called #listen!, by origin id.
    # A fanout freezes itself (every connection Ractor reads it through a
    # module constant), so it can't record this on itself; a frozen list
    # in a module ivar is written from the main Ractor, where #listen! runs
    # at boot, and read from any Ractor, where #register runs.
    #
    # Also what both fanouts' subscribers share for surviving a dropped
    # connection: the reconnect backoff and a log that can't end them.
    module Listeners
      # 500 ms doubling to 30 s, the same curve as monk_live.js's reconnect.
      RETRY_INITIAL = 0.5
      RETRY_MAX = 30

      # What a subscriber closes every open socket with after reconnecting:
      # what was published while it was down is lost, and no client can
      # tell (its seq counts what this process sent it), so each must
      # reconnect and resync (ADR 0011).
      MISSED_CODE = 1011
      MISSED_REASON = "missed broadcasts".freeze

      @origins = [].freeze

      class << self
        def listening?(origin) = @origins.include?(origin)

        def next_delay(delay) = [delay * 2, RETRY_MAX].min

        # Monk::Log writes to log/<env>.log once Monk has booted. Logging
        # must never end a subscriber, whatever state Monk::Log is in.
        def log(source, level, message)
          Monk::Log.public_send(level, "#{source}: #{message}")
        rescue StandardError
          nil
        end

        # Main Ractor only -- a module ivar write from another Ractor raises
        # Ractor::IsolationError, which is the right answer for a boot-time
        # call made from the wrong place.
        def add(origin)
          @origins = Ractor.make_shareable([*@origins, origin])
        end
      end
    end
  end
end
