module Monk
  module WebSocket
    # Which fanouts in this process have called #listen!, by origin id.
    # A fanout freezes itself (every connection Ractor reads it through a
    # module constant), so it can't record this on itself; a frozen list
    # in a module ivar is written from the main Ractor, where #listen! runs
    # at boot, and read from any Ractor, where #register runs.
    module Listeners
      @origins = [].freeze

      class << self
        def listening?(origin) = @origins.include?(origin)

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
