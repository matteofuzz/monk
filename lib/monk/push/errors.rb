module Monk
  module Push
    # A VAPID key that isn't a base64url P-256 key, or a private key that
    # doesn't go with the public one. Raised at boot by configure.
    class InvalidKeyError < ArgumentError
    end

    # A browser's subscription whose keys (p256dh, auth) can't be used:
    # not base64url, the wrong length, or not a point on P-256. The
    # caller's input, as a subscribe route passes it on.
    class InvalidSubscriptionError < ArgumentError
    end

    # A payload over Encryption::MAX_PAYLOAD bytes: once encrypted it
    # wouldn't fit the 4096 bytes every push service accepts.
    class PayloadTooLargeError < ArgumentError
    end
  end
end
