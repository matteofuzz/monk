# Monk::Push.notify, its job and Monk::Push::Sweep. Loaded at the end of
# whichever of monk/push and monk/jobs is required second, once both are
# defined (docs/adr/0017), so it requires neither itself.

module Monk
  module Push
    # Sends one message to one subscription, from a job process. Enqueued
    # by Monk::Push.notify, one per subscription, so a retry resends only
    # to the device that failed (docs/plan-pwa-push.md decision 5).
    class DeliveryJob < Monk::Job
      queue "push"
      never_retry RejectedError, PayloadTooLargeError, InvalidSubscriptionError

      # payload: the bytes notify checked, as a String. A subscription
      # that stopped counting since (gone, its session revoked) is skipped.
      def self.perform(subscription_id, payload, options = {})
        subscription = Store.find(Monk::Push.config[:db_name], subscription_id)
        return :skipped unless subscription

        Delivery.deliver(Monk::Push.config, subscription, payload, options)
      end
    end

    # Monk::Push.sweep! as a job, nightly in config/recurring.rb when push
    # is installed:
    #
    #   Monk::Jobs.recurring "monk_push_sweep", Monk::Push::Sweep, cron: "27 3 * * *" if defined?(Monk::Push::Sweep)
    class Sweep < Monk::Job
      def self.perform
        Monk::Log.info("Monk::Push::Sweep: deleted #{Monk::Push.sweep!} subscriptions")
      end
    end

    class << self
      # A notification to every device where subject is signed in and
      # allowed notifications: one DeliveryJob each. Returns how many were
      # enqueued (0 when none counts). payload: a Hash (sent as JSON) or a
      # String, at most Encryption::MAX_PAYLOAD bytes, checked here, in the
      # caller. ttl: seconds a push service keeps it for an offline device
      # (a day by default); urgency: very-low, low, normal or high; topic:
      # a newer message with the same topic replaces one still waiting.
      # conn: enqueues inside the caller's transaction.
      #
      #   Monk::Push.notify(recipient, { title: "Ann", body: "Lunch?", url: "/chats/7" }, topic: "chat-7")
      def notify(subject, payload, ttl: Delivery::TTL, urgency: nil, topic: nil, conn: nil)
        bytes = Delivery.payload_bytes(payload)
        options = Delivery.options(ttl: ttl, urgency: urgency, topic: topic)
        # A job's arguments are JSON: the payload goes as text.
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        targets = subscriptions(subject)
        targets.each { |subscription| DeliveryJob.enqueue(subscription[:id], text, options, conn: conn) }
        targets.size
      end
    end
  end
end
