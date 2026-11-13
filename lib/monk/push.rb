require_relative "../monk"
require_relative "push/errors"
require_relative "push/base64_url"
require_relative "push/keys"
require_relative "push/encryption"
require_relative "push/vapid"

# Opt-in: require "monk/push" explicitly; `require "monk"` alone doesn't
# load it. Web push to the browsers people allowed it in
# (docs/plan-pwa-push.md, part B): the encryption (RFC 8291) and the VAPID
# header (RFC 8292) are written here over OpenSSL, with no gem, the way
# Storage signs its own S3 requests.
module Monk
  module Push
  end
end
