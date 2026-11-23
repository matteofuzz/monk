require_relative "../monk"
require_relative "auth"
require_relative "push/errors"
require_relative "push/base64_url"
require_relative "push/keys"
require_relative "push/encryption"
require_relative "push/vapid"
require_relative "push/subscription"
require_relative "push/store"
require_relative "push/delivery"
require_relative "push/helpers"

# Opt-in: require "monk/push" explicitly; `require "monk"` alone doesn't load
# it. Web push to the browsers people allowed it in: the encryption (RFC 8291)
# and the VAPID header (RFC 8292) are written here over OpenSSL, with no gem,
# the way Storage signs its own S3 requests.
module Monk
  Context.include(Push::Helpers)

  module Push
    CLIENT_DIR = File.expand_path("push/client", __dir__).freeze
    # push.js and state.js, served from the gem like Live's client.
    CLIENT_PATH = "/_monk/push".freeze
    Monk::Assets.mount(CLIENT_PATH, CLIENT_DIR)
    # The app's route a page POSTs its subscription to and DELETEs it
    # from (the push-subscribe example).
    PATH = "/push/subscription".freeze

    # The JWT's sub: who the push service can reach about this app.
    # Apple refuses a push without one.
    CONTACT = %r{\A(mailto:[^@\s]+@[^@\s]+|https?://\S+)\z}
    # Hosts no one can be reached at. Apple answers 403 BadJwtToken to a
    # contact on one (checked on an iPhone: mailto:push@shop.example).
    UNREACHABLE_HOST = /(\A|\.)(localhost|example|test|invalid|local)\z|\Aexample\.(com|net|org)\z|\A[\d.]+\z|:/

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
      # https: URL, the JWT's sub, on a real domain (config/push.rb
      # defaults it to PUBLIC_URL). Outside development and test a contact
      # no one can be reached at (localhost, an IP, .example, .test) fails
      # the boot, since Apple refuses every push signed with it; in
      # development and test it's a warning. db_name: where the
      # subscriptions table is. path: the app's subscribe route, which
      # push.js calls.
      def configure(db_name:, public_key:, private_key:, contact:, path: PATH)
        keys = checked_keys(public_key, private_key)
        contact = checked_contact(contact)

        raise ArgumentError, "Monk::Push.configure(path:) is a path, got #{path.inspect}" unless
          path.is_a?(String) && path.start_with?("/")

        @config = Ractor.make_shareable({ db_name: db_name, contact: contact, path: path.dup, **keys })
      end

      def configured? = !@config.nil?

      # The VAPID public key, base64url: what a page gives the browser as
      # applicationServerKey.
      def public_key = current[:public_key]

      # Stores the subscription a browser made (its PushSubscription
      # JSON, from the page) for the signed-in session session_token
      # names: the session cookie's raw token. Returns { id:, subject: },
      # or nil when that session is unknown, revoked or expired (answer
      # 401). The same browser subscribing again -- every page load does
      # -- updates its row, and moves it to this session's person.
      # InvalidSubscriptionError for a subscription a browser wouldn't send.
      def subscribe(session_token:, subscription:, user_agent: nil)
        return nil if session_token.nil? || session_token.empty?

        parsed = Subscription.parse(subscription)
        Store.subscribe(db_name, Monk::Auth.token_hash(session_token), parsed, user_agent&.slice(0, 512))
      end

      # Forgets the browser with this endpoint (the page's "turn off").
      # The endpoint is the browser's own secret URL, so knowing it is
      # proof enough. Returns whether there was one.
      def unsubscribe(endpoint) = Store.unsubscribe(db_name, endpoint.to_s)

      # The subscriptions that count for subject, oldest first:
      # [{ id:, subject:, endpoint:, p256dh:, auth: }].
      def subscriptions(subject) = Store.for_subject(db_name, subject.to_s)

      # { subject => true/false } for each subject: whether a notification
      # would reach at least one device. One query, for a page listing
      # people (shaped like Monk::Presence.status).
      def subscribed(subjects) = Store.subscribed(db_name, Array(subjects))

      def subscribed?(subject) = subscribed([subject]).fetch(subject.to_s)

      # Sends payload to one subscription now, in this process: what
      # Monk::Push::DeliveryJob runs; notify is the usual call. subscription
      # is one of subscriptions(subject). Returns :delivered, or :gone when
      # the push service says it no longer exists (its row is deleted).
      # Raises RejectedError (final) or DeliveryError (worth retrying).
      def deliver(subscription, payload, ttl: Delivery::TTL, urgency: nil, topic: nil)
        Delivery.deliver(current, subscription, Delivery.payload_bytes(payload),
          Delivery.options(ttl: ttl, urgency: urgency, topic: topic),)
      end

      # Deletes subscriptions that no longer count: a revoked or expired
      # session's, and those past the browser's expirationTime. Returns how
      # many. Run nightly by Monk::Push::Sweep.
      def sweep!(batch_size: 1000)
        unless batch_size.is_a?(Integer) && batch_size.positive?
          raise ArgumentError, "batch_size: must be a positive Integer, got #{batch_size.inspect}"
        end

        Store.sweep(db_name, batch_size)
      end

      # Test-only.
      def reset!
        @config = nil
      end

      private

      def current
        config || raise(NotConfiguredError, "Monk::Push isn't configured -- call Monk::Push.configure first")
      end

      def db_name = current[:db_name]

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

      def checked_contact(contact)
        unless contact.is_a?(String) && contact.match?(CONTACT)
          raise ArgumentError, "Monk::Push.configure(contact:) is a mailto: or https: URL (VAPID_CONTACT, or " \
                               "PUBLIC_URL by default), got #{contact.inspect}"
        end
        problem = contact_problem(contact)
        return contact.dup unless problem

        message = "Monk::Push.configure(contact:) #{contact.inspect} #{problem}: Apple refuses every push signed " \
                  "with it (403 BadJwtToken). Set VAPID_CONTACT, or PUBLIC_URL, to an address on a real domain."
        raise ArgumentError, message unless Monk.env.development? || Monk.env.test?

        Log.warn(message)
        contact.dup
      end

      def contact_problem(contact)
        return "isn't https" if contact.start_with?("http://")

        host = contact.start_with?("mailto:") ? contact.split("@", 2).last : URI.parse(contact).host.to_s
        "is on #{host}, where no one can be reached" if host.downcase.match?(UNREACHABLE_HOST)
      rescue URI::InvalidURIError
        "isn't a URL"
      end
    end
  end
end

# Monk::Push.notify and its job, when jobs are loaded too -- either order
# works (docs/adr/0017).
require_relative "push/later" if Monk.const_defined?(:Jobs)
