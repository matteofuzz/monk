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
    # The JWT's sub: who the push service can reach about this app.
    # Apple refuses a push without one.
    CONTACT = %r{\A(mailto:[^@\s]+@[^@\s]+|https://\S+)\z}

    # Eager, never `@x ||=` (a lazy write from a worker Ractor is an
    # isolation error).
    @config = nil

    class << self
      attr_reader :config

      # Boot-time, main Ractor, from config/push.rb:
      #
      #   Monk::Push.configure(db_name: :primary, public_key: ENV["VAPID_PUBLIC_KEY"],
      #                        private_key: ENV["VAPID_PRIVATE_KEY"], contact: ENV["VAPID_CONTACT"])
      #
      # public_key and private_key: the VAPID pair, base64url (`monk push
      # keys` makes one). The private key must be the public key's, or
      # every push service would refuse every message: that's checked
      # here, so a mismatched pair fails the boot. contact: a mailto: or
      # https: URL, the JWT's sub. db_name: where the subscriptions table
      # is.
      def configure(db_name:, public_key:, private_key:, contact:)
        keys = checked_keys(public_key, private_key)
        unless contact.is_a?(String) && contact.match?(CONTACT)
          raise ArgumentError, "Monk::Push.configure(contact:) is a mailto: or https: URL (VAPID_CONTACT), " \
                               "got #{contact.inspect}"
        end

        @config = Ractor.make_shareable({ db_name: db_name, contact: contact.dup, **keys })
      end

      def configured? = !@config.nil?

      # The VAPID public key, base64url: what a page gives the browser as
      # applicationServerKey.
      def public_key = current[:public_key]

      # Test-only.
      def reset!
        @config = nil
      end

      private

      def current
        config || raise(NotConfiguredError, "Monk::Push isn't configured -- call Monk::Push.configure first")
      end

      def checked_keys(public_key, private_key)
        { public_key: public_key, private_key: private_key }.each do |name, value|
          next if value.is_a?(String) && !value.strip.empty?

          variable = name == :public_key ? "VAPID_PUBLIC_KEY" : "VAPID_PRIVATE_KEY"
          raise InvalidKeyError,
            "Monk::Push.configure(#{name}:) is missing (#{variable}); `monk push keys` makes a pair"
        end
        derived = begin
          Keys.public_key_for(private_key)
        rescue ArgumentError => e
          raise InvalidKeyError, "VAPID_PRIVATE_KEY isn't a P-256 private key: #{e.message}"
        end
        unless OpenSSL.secure_compare(derived, public_key)
          raise InvalidKeyError, "VAPID_PRIVATE_KEY doesn't go with VAPID_PUBLIC_KEY: they must come from the same " \
                                 "`monk push keys`"
        end

        { public_key: public_key.dup, private_key: private_key.dup }
      end
    end
  end
end
