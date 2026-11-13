module Monk
  module Push
    # base64url without padding, the encoding of everything web push
    # exchanges: the browser's keys, VAPID keys, the JWT. Written with
    # pack("m0") as Storage::Token is, not the base64 gem.
    module Base64Url
      ALPHABET = /\A[A-Za-z0-9_-]*\z/

      module_function

      def encode(bytes)
        [bytes].pack("m0").tr("+/", "-_").delete("=")
      end

      # Bytes (binary String), or ArgumentError for anything that isn't
      # base64url. Padding is accepted, since some browsers' JSON had it.
      def decode(text)
        text = text.to_s.delete_suffix("==").delete_suffix("=")
        raise ArgumentError, "not base64url" unless text.match?(ALPHABET) && text.length % 4 != 1

        (text.tr("-_", "+/") + ("=" * (-text.length % 4))).unpack1("m0")
      end
    end
  end
end
