require_relative "../mail"
require_relative "../jobs"

module Monk
  module Mail
    # Sends one message from a job process (docs/adr/0014-mail-from-jobs-and-login-links-created-in-the-job.md).
    # Enqueued by Monk::Mail.deliver_later, never directly: its argument
    # is the message's fields, already checked and with from: resolved.
    class DeliveryJob < Monk::Job
      queue "mailers"
      never_retry PermanentDeliveryError

      # The SMTP failures that are final, by class name so this file never
      # loads net/smtp itself (the app's Gemfile decides that, ADR 0012):
      # a 5xx reply, a malformed command, refused credentials. Everything
      # else -- a 4xx "try later", a refused connection, TLS, a timeout --
      # is worth retrying.
      PERMANENT_SMTP_ERRORS = %w[Net::SMTPFatalError Net::SMTPSyntaxError Net::SMTPAuthenticationError].freeze

      def self.perform(fields)
        Monk::Mail.deliver(**fields.transform_keys(&:to_sym))
      rescue DeliveryError => e
        raise unless PERMANENT_SMTP_ERRORS.include?(e.cause&.class&.name)

        raise PermanentDeliveryError, e.message
      end
    end

    class << self
      # deliver, later: the same arguments, plus enqueue's wait:, at: and
      # conn: (the last one enqueues inside the caller's transaction, so the
      # email commits or rolls back with the app's own writes). Returns the
      # job's id. The message is built -- and so checked -- here, before
      # anything is enqueued: bad input raises InvalidMessageError in the
      # caller, exactly as deliver would, rather than failing later in the
      # job process. Render HTML before calling (html: Monk::Mail.render(...)):
      # the job stores the finished message and only sends it.
      #
      #   Monk::Mail.deliver_later(to: order[:email], subject: "Your receipt", text: receipt_text)
      def deliver_later(to:, subject:, text: nil, html: nil, reply_to: nil, from: nil, wait: nil, at: nil, conn: nil)
        raise NotConfiguredError, "call Monk::Mail.configure(url:, from:) before Monk::Mail.deliver_later" unless config

        from ||= config[:from]
        if from.nil?
          raise InvalidMessageError, "no from: given, and Monk::Mail.configure has no default from: (MAIL_FROM)"
        end

        message = Message.new(from: from, to: to, subject: subject, text: text, html: html, reply_to: reply_to)
        DeliveryJob.enqueue(message.to_h.transform_keys(&:to_s), wait: wait, at: at, conn: conn)
      end
    end
  end
end
