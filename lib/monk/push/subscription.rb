require "uri"

module Monk
  module Push
    # One browser's subscription, checked: what PushSubscription.toJSON()
    # gives a page, {"endpoint", "expirationTime", "keys": {"p256dh",
    # "auth"}}, as a subscribe route receives it.
    Subscription = Data.define(:endpoint, :p256dh, :auth, :expires_at)

    class Subscription
      # Endpoints are a few hundred characters; a longer one isn't a push
      # service's.
      MAX_ENDPOINT = 2048
      # http only on this machine: Monk's own tests stand a push service up
      # there. Every real push service is https.
      LOOPBACK = %w[127.0.0.1 localhost ::1 [::1]].freeze

      # string or symbol keys; InvalidSubscriptionError for anything a
      # browser wouldn't send.
      def self.parse(json)
        raise InvalidSubscriptionError, "a subscription is an object, got #{json.class}" unless json.is_a?(Hash)

        json = json.transform_keys(&:to_s)
        keys = json["keys"].is_a?(Hash) ? json["keys"].transform_keys(&:to_s) : {}
        endpoint = checked_endpoint(json["endpoint"])
        Encryption.subscription_keys(keys["p256dh"].to_s, keys["auth"].to_s)

        new(endpoint: endpoint, p256dh: keys["p256dh"], auth: keys["auth"],
          expires_at: expiration(json["expirationTime"]),)
      end

      def self.checked_endpoint(endpoint)
        uri = URI.parse(endpoint.to_s)
        allowed = uri.is_a?(URI::HTTPS) || (uri.is_a?(URI::HTTP) && LOOPBACK.include?(uri.host))
        unless allowed && uri.host && endpoint.length <= MAX_ENDPOINT
          raise InvalidSubscriptionError, "a subscription's endpoint is an https URL"
        end

        endpoint
      rescue URI::InvalidURIError
        raise InvalidSubscriptionError, "a subscription's endpoint is an https URL"
      end

      # expirationTime: milliseconds since the epoch, or null (most
      # browsers).
      def self.expiration(milliseconds)
        return nil if milliseconds.nil?
        raise InvalidSubscriptionError, "expirationTime is milliseconds or null" unless milliseconds.is_a?(Numeric)

        Time.at(milliseconds / 1000.0).utc
      end
    end
  end
end
