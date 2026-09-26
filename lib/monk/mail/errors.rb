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

    class MissingDependencyError < StandardError
    end

    class ViewsNotFrozenError < StandardError
    end

    class NotConfiguredError < StandardError
    end

    # A send that failed on the way out -- network, TLS, or the server
    # refusing it. The transport's own exception is the #cause.
    class DeliveryError < StandardError
    end
  end
end
