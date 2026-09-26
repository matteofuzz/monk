module Monk
  module Mail
    # An ArgumentError: it's always the caller's input that's wrong, never
    # the transport or the network.
    class InvalidMessageError < ArgumentError
    end
  end
end
