require "openssl"

module Monk
  module Push
    # P-256 keys from and to the raw bytes web push uses: a 65-byte
    # uncompressed point for a public key, a 32-byte scalar for a private
    # one. OpenSSL 3 keys are immutable and only built from DER, so the raw
    # bytes are wrapped in DER here. PKey objects can't be made shareable,
    # so configuration keeps raw Strings and each send rebuilds the key it
    # needs (docs/plan-pwa-push.md, B2).
    module Keys
      CURVE = "prime256v1".freeze
      PUBLIC_SIZE = 65
      PRIVATE_SIZE = 32
      # SubjectPublicKeyInfo for an EC P-256 key, up to the point itself.
      SPKI_PREFIX = ["3059301306072a8648ce3d020106082a8648ce3d030107034200"].pack("H*").freeze

      module_function

      # A new VAPID key pair, base64url: { public_key:, private_key: }.
      def generate
        key = OpenSSL::PKey::EC.generate(CURVE)
        { public_key: Base64Url.encode(raw_public(key)), private_key: Base64Url.encode(raw_private(key)) }
      end

      # The public key (base64url) that goes with a private one (base64url).
      def public_key_for(private_key)
        Base64Url.encode(raw_public(private_pkey(decode(private_key, PRIVATE_SIZE, "private"))))
      end

      # A public key from its 65 raw bytes; ArgumentError if they aren't a
      # point on the curve.
      def public_pkey(raw)
        raise ArgumentError, "a P-256 public key is #{PUBLIC_SIZE} bytes, got #{raw.bytesize}" unless
          raw.bytesize == PUBLIC_SIZE && raw.getbyte(0) == 4

        OpenSSL::PKey.read(SPKI_PREFIX + raw)
      rescue OpenSSL::PKey::PKeyError
        raise ArgumentError, "not a point on P-256"
      end

      # A private key from its 32 raw bytes, its public point computed from
      # them (an ECPrivateKey needs both).
      def private_pkey(raw)
        raise ArgumentError, "a P-256 private key is #{PRIVATE_SIZE} bytes, got #{raw.bytesize}" unless
          raw.bytesize == PRIVATE_SIZE

        group = OpenSSL::PKey::EC::Group.new(CURVE)
        scalar = OpenSSL::BN.new(raw, 2)
        raise ArgumentError, "not a P-256 private key" if scalar.zero? || scalar >= group.order

        point = group.generator.mul(scalar)
        OpenSSL::PKey::EC.new(OpenSSL::ASN1::Sequence([
          OpenSSL::ASN1::Integer(1),
          OpenSSL::ASN1::OctetString(raw),
          OpenSSL::ASN1::ObjectId(CURVE, 0, :EXPLICIT, :CONTEXT_SPECIFIC),
          OpenSSL::ASN1::BitString(point.to_octet_string(:uncompressed), 1, :EXPLICIT, :CONTEXT_SPECIFIC),
        ]).to_der)
      rescue OpenSSL::PKey::PKeyError, OpenSSL::PKey::EC::Point::Error
        raise ArgumentError, "not a P-256 private key"
      end

      def raw_public(key) = key.public_key.to_octet_string(:uncompressed)
      def raw_private(key) = key.private_key.to_s(2).rjust(PRIVATE_SIZE, "\0".b)

      # raw bytes of a base64url key, checked for size.
      def decode(text, size, what)
        raw = Base64Url.decode(text)
        raise ArgumentError, "a P-256 #{what} key is #{size} bytes, got #{raw.bytesize}" unless raw.bytesize == size

        raw
      end
    end
  end
end
