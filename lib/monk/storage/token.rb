require "json"
require "openssl"

module Monk
  module Storage
    # The file backend's signed links: /_monk/storage/<token> stands in
    # for a bucket's signed URL. A token is base64url(JSON payload) + "." +
    # base64url(HMAC-SHA256 of that first part), the payload
    # {m: "GET"|"PUT", k: key, e: expires_at, l: length, t: type}, l and t
    # for uploads only (docs/plan-storage.md decision 8).
    module Token
      module_function

      def sign(payload, secret)
        body = encode(JSON.generate(payload))
        "#{body}.#{encode(OpenSSL::HMAC.digest("SHA256", secret, body))}"
      end

      # The payload, with symbol keys, or nil when the token is malformed
      # or its signature doesn't match. Expiry is the caller's check.
      def verify(token, secret)
        body, signature = token.split(".", -1)
        return nil unless body && signature && token.count(".") == 1

        expected = encode(OpenSSL::HMAC.digest("SHA256", secret, body))
        return nil unless OpenSSL.secure_compare(expected, signature)

        payload = JSON.parse(decode(body), symbolize_names: true)
        payload.is_a?(Hash) ? payload : nil
      rescue JSON::ParserError, ArgumentError
        nil
      end

      def encode(bytes)
        [bytes].pack("m0").tr("+/", "-_").delete("=")
      end

      def decode(text)
        raise ArgumentError, "not base64url" unless text.match?(/\A[A-Za-z0-9_-]*\z/)

        (text.tr("-_", "+/") + ("=" * (-text.length % 4))).unpack1("m0")
      end
    end
  end
end
