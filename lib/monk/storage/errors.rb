module Monk
  module Storage
    class NotConfiguredError < StandardError
    end

    class InvalidStorageUrlError < StandardError
    end

    class MissingStorageUrlError < StandardError
    end

    class MissingStorageSecretError < StandardError
    end

    # An ArgumentError: a key is always the caller's input.
    class InvalidKeyError < ArgumentError
    end

    # get or copy of a key that isn't there.
    class NotFoundError < StandardError
    end

    # A call that failed on the way to or from the backend -- network, TLS,
    # the disk, or the bucket refusing it. The original exception is the
    # #cause, the way Monk::Mail::DeliveryError works.
    class RequestError < StandardError
    end

    # Bytes that must never be served as uploaded (SVG, which can carry
    # scripts).
    class UnsafeContentError < StandardError
    end
  end
end
