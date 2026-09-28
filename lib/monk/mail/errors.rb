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

    # A DeliveryError the server made final: an SMTP 5xx (no such mailbox,
    # relaying refused) or refused credentials. Raised by
    # Monk::Mail::DeliveryJob (require "monk/mail/later") so the job isn't
    # retried; still a DeliveryError, so a rescue of that catches it too.
    class PermanentDeliveryError < DeliveryError
    end
  end
end
