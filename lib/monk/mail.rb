require_relative "freeze_hooks"
require_relative "environment"
require_relative "log"
require_relative "mail/errors"
require_relative "mail/address"
require_relative "mail/mime"
require_relative "mail/message"
require_relative "mail/transports"
require_relative "mail/url"

module Monk
  # Sending email. Opt-in: require "monk/mail" explicitly -- `require
  # "monk"` alone does not load this. Text and/or HTML messages only, MIME
  # built by Monk itself, since the `mail` gem can't run inside a worker
  # Ractor (docs/adr/0012-minimal-built-in-mailer.md).
  module Mail
    class << self
      # Typically, in config/mail.rb:
      #
      #   Monk::Mail.configure(url: ENV["MAIL_URL"], from: ENV["MAIL_FROM"])
      #
      # url: picks the transport (smtp://, smtps://, log://) and is parsed
      # here, so a bad one fails the boot. Unset or empty means log:// in
      # development and raises everywhere else -- same posture as
      # Monk::Auth.deliver_link: an app that forgot to wire mail should
      # find out at boot, not when a user never gets their login link.
      # from: is the default sender, optional since each send can pass its own.
      def configure(url:, from: nil)
        Fields.header!(:from, from) unless from.nil?

        @config = { transport: transport_for(url), from: from }
      end

      attr_reader :config

      # Called from Base#freeze! (Seam B), via Monk.freeze_hooks. Freezes
      # the value, not the module, same as Monk::Auth.freeze_registry! --
      # an unfrozen config Hash can't be read from a worker Ractor at all.
      def freeze_registry!
        @config = Ractor.make_shareable(@config)
      end

      # Test-only: drops the current config. Not part of the app-facing API.
      def reset!
        @config = nil
      end

      private

      def transport_for(url)
        return URL.parse(url) unless url.nil? || url.empty?
        return Transports::Log.new if Monk.env.development?

        raise MissingMailUrlError,
          "Monk::Mail.configure(url:) is empty and this isn't development (MONK_ENV=#{Monk.env}) -- " \
          "no email would ever be sent. Set MAIL_URL, e.g. smtp://user:pass@smtp.example.com:587, " \
          "or log:// if logging messages instead of sending them is truly intended here."
      end
    end

    Monk.freeze_hooks << self
  end
end
