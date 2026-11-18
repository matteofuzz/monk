require "openssl"
require "securerandom"

module Monk
  module Push
    # A push message's body, encrypted for one browser's subscription:
    # RFC 8291 (ECDH with the browser's p256dh key, HKDF with its auth
    # secret) in RFC 8188's aes128gcm content coding, one record. The
    # result is the POST body, sent with `Content-Encoding: aes128gcm`.
    module Encryption
      RECORD_SIZE = 4096
      SALT_SIZE = 16
      AUTH_SIZE = 16
      TAG_SIZE = 16
      # salt, record size, key id length, the server's public key.
      HEADER_SIZE = SALT_SIZE + 4 + 1 + Keys::PUBLIC_SIZE
      # What fits the 4096 bytes push services take: the header, the
      # AES-GCM tag and the one-byte padding delimiter come off.
      MAX_PAYLOAD = RECORD_SIZE - HEADER_SIZE - TAG_SIZE - 1

      module_function

      # payload: bytes (a String). p256dh and auth: the subscription's
      # keys, base64url, as the browser gives them. salt: and server_key:
      # are fresh for every message; only the RFC's test vector sets them.
      def encrypt(payload, p256dh:, auth:, salt: SecureRandom.random_bytes(SALT_SIZE),
                  server_key: OpenSSL::PKey::EC.generate(Keys::CURVE))
        payload = payload.b
        if payload.bytesize > MAX_PAYLOAD
          raise PayloadTooLargeError, "a push payload is at most #{MAX_PAYLOAD} bytes, got #{payload.bytesize}"
        end

        ua_public, auth_secret = subscription_keys(p256dh, auth)
        server_public = Keys.raw_public(server_key)
        shared = server_key.derive(Keys.public_pkey(ua_public))
        ikm = hkdf(shared, auth_secret, "WebPush: info\0".b + ua_public + server_public, 32)
        key = hkdf(ikm, salt, "Content-Encoding: aes128gcm\0".b, 16)
        nonce = hkdf(ikm, salt, "Content-Encoding: nonce\0".b, 12)

        salt + [RECORD_SIZE, server_public.bytesize].pack("NC") + server_public + seal(key, nonce, payload + "\x02".b)
      end

      def subscription_keys(p256dh, auth)
        ua_public = Base64Url.decode(p256dh)
        auth_secret = Base64Url.decode(auth)
        unless auth_secret.bytesize == AUTH_SIZE
          raise InvalidSubscriptionError, "a subscription's auth is #{AUTH_SIZE} bytes, got #{auth_secret.bytesize}"
        end

        Keys.public_pkey(ua_public)
        [ua_public, auth_secret]
      rescue InvalidSubscriptionError
        raise
      rescue ArgumentError => e
        raise InvalidSubscriptionError, "a subscription's keys can't be used: #{e.message}"
      end

      def hkdf(ikm, salt, info, length)
        OpenSSL::KDF.hkdf(ikm, salt: salt, info: info, length: length, hash: "SHA256")
      end

      def seal(key, nonce, plaintext)
        cipher = OpenSSL::Cipher.new("aes-128-gcm").encrypt
        cipher.key = key
        cipher.iv = nonce
        cipher.update(plaintext) + cipher.final + cipher.auth_tag
      end
    end
  end
end
