require "json"
require "net/http"
require "openssl"
require "uri"
require_relative "../log"

module Monk
  module Push
    # One message to one subscription: encrypted, signed, POSTed to its
    # endpoint, and the push service's answer turned into what to do
    # (docs/plan-pwa-push.md, B4).
    module Delivery
      # How long a push service keeps a message for a device that's
      # offline: a day by default. 0 means now or never.
      TTL = 86_400
      MAX_TTL = 28 * 86_400
      URGENCIES = %w[very-low low normal high].freeze
      # RFC 8030: a Topic is up to 32 base64url characters; a message with
      # the same topic replaces one still waiting.
      TOPIC = /\A[A-Za-z0-9_-]{1,32}\z/
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 10

      module_function

      # The payload as bytes: a Hash or Array becomes JSON, a String is
      # sent as it is. Checked against Encryption::MAX_PAYLOAD.
      def payload_bytes(payload)
        bytes = payload.is_a?(String) ? payload.b : JSON.generate(payload).b
        if bytes.bytesize > Encryption::MAX_PAYLOAD
          raise PayloadTooLargeError,
            "a push payload is at most #{Encryption::MAX_PAYLOAD} bytes, got #{bytes.bytesize}"
        end

        bytes
      end

      # { "ttl" =>, "urgency" =>, "topic" => }, checked, string keys (a
      # job's arguments).
      def options(ttl: TTL, urgency: nil, topic: nil)
        raise ArgumentError, "ttl: is 0..#{MAX_TTL} seconds, got #{ttl.inspect}" unless
          ttl.is_a?(Integer) && ttl.between?(0, MAX_TTL)
        raise ArgumentError, "urgency: is one of #{URGENCIES.join(", ")}, got #{urgency.inspect}" unless
          urgency.nil? || URGENCIES.include?(urgency.to_s)
        raise ArgumentError, "topic: is 1-32 base64url characters, got #{topic.inspect}" unless
          topic.nil? || topic.to_s.match?(TOPIC)

        { "ttl" => ttl, "urgency" => urgency&.to_s, "topic" => topic&.to_s }.compact
      end

      # :delivered, or :gone when the push service says the subscription
      # no longer exists (404/410: the user turned notifications off, or
      # the app was uninstalled) -- its row is deleted. RejectedError for a
      # final refusal, DeliveryError for one worth retrying.
      def deliver(config, subscription, bytes, options)
        body = Encryption.encrypt(bytes, p256dh: subscription[:p256dh], auth: subscription[:auth])
        authorization = Vapid.authorization(subscription[:endpoint], public_key: config[:public_key],
          private_key: config[:private_key], contact: config[:contact],)
        response = post(subscription[:endpoint], body, authorization, options)
        outcome(config, subscription, response)
      end

      def post(endpoint, body, authorization, options)
        uri = URI.parse(endpoint)
        headers = {
          "authorization" => authorization, "content-encoding" => "aes128gcm",
          "content-type" => "application/octet-stream", "ttl" => options.fetch("ttl", TTL).to_s,
        }
        headers["urgency"] = options["urgency"] if options["urgency"]
        headers["topic"] = options["topic"] if options["topic"]
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        http.write_timeout = READ_TIMEOUT
        http.start { |connection| connection.post(uri.request_uri, body, headers) }
      rescue IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse,
             Net::ProtocolError => e
        log(:warn, subscription_host(endpoint), "failed=#{e.class}")
        raise DeliveryError, "push to #{subscription_host(endpoint)} failed: #{e.class}: #{e.message}"
      end

      def outcome(config, subscription, response)
        host = subscription_host(subscription[:endpoint])
        code = response.code.to_i
        line = "subscription=#{subscription[:id]} status=#{code}"
        case code
        when 200..299
          Store.succeeded(config[:db_name], subscription[:id])
          log(:info, host, line)
          :delivered
        when 404, 410
          Store.delete(config[:db_name], subscription[:id])
          log(:info, host, "#{line} gone")
          :gone
        when 401, 403
          log(:error, host,
            "#{line} refused the VAPID header: check VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_CONTACT",)
          raise RejectedError, "#{host} refused the VAPID header (#{code}): #{reason(response)}"
        when 400, 413
          log(:error, host, line)
          raise RejectedError, "#{host} refused the message (#{code}): #{reason(response)}"
        else
          log(:warn, host, line)
          raise DeliveryError, "#{host} answered #{code}: #{reason(response)}"
        end
      end

      # The endpoint's host only: the rest of the URL is the browser's
      # secret, so it never reaches a log or an error message.
      def subscription_host(endpoint) = URI.parse(endpoint).host

      def reason(response) = response.body.to_s.strip[0, 200]

      def log(level, host, detail)
        Monk::Log.public_send(level, "[push] host=#{host} #{detail}")
      end
    end
  end
end
