require "json"
require "openssl"
require "uri"

module Monk
  module Push
    # The Authorization header that identifies the app to a push service:
    # RFC 8292's `vapid t=<JWT>, k=<public key>`, with an ES256 JWT whose
    # audience is the endpoint's origin. Signed for every send: a Ractor
    # can't keep a cache, and signing costs far less than the request.
    module Vapid
      # Push services refuse an exp more than 24 hours ahead.
      EXPIRES_IN = 12 * 3600
      MAX_EXPIRES_IN = 24 * 3600
      HEADER = Base64Url.encode(JSON.generate(typ: "JWT", alg: "ES256")).freeze

      module_function

      # public_key and private_key: the VAPID pair, base64url. contact:
      # the JWT's sub, a mailto: or https: URL.
      def authorization(endpoint, public_key:, private_key:, contact:, now: Time.now.to_i, expires_in: EXPIRES_IN)
        unless expires_in.is_a?(Integer) && expires_in.positive? && expires_in <= MAX_EXPIRES_IN
          raise ArgumentError, "expires_in: is 1..#{MAX_EXPIRES_IN} seconds, got #{expires_in.inspect}"
        end

        claims = Base64Url.encode(JSON.generate(aud: audience(endpoint), exp: now + expires_in, sub: contact))
        input = "#{HEADER}.#{claims}"
        key = Keys.private_pkey(Keys.decode(private_key, Keys::PRIVATE_SIZE, "private"))
        "vapid t=#{input}.#{Base64Url.encode(raw_signature(key.sign("SHA256", input)))}, k=#{public_key}"
      end

      # "https://fcm.googleapis.com": the endpoint's scheme, host and a
      # port only when it isn't the scheme's default.
      def audience(endpoint)
        uri = URI.parse(endpoint)
        raise ArgumentError, "a push endpoint is an http(s) URL, got #{endpoint.inspect}" unless
          uri.is_a?(URI::HTTP) && uri.host

        port = ":#{uri.port}" unless uri.port == uri.default_port
        "#{uri.scheme}://#{uri.host}#{port}"
      rescue URI::InvalidURIError
        raise ArgumentError, "a push endpoint is an http(s) URL, got #{endpoint.inspect}"
      end

      # JWS wants r || s, 32 bytes each; OpenSSL signs in DER.
      def raw_signature(der)
        OpenSSL::ASN1.decode(der).value.map { |integer| integer.value.to_s(2).rjust(32, "\0".b) }.join
      end
    end
  end
end
