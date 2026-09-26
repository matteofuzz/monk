module Monk
  module Mail
    # An ArgumentError: it's always the caller's input that's wrong, never
    # the transport or the network.
    class InvalidMessageError < ArgumentError
    end

    class InvalidMailUrlError < StandardError
    end

    class MissingMailUrlError < StandardError
    end
  end
end
