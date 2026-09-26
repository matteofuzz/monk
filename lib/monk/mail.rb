require_relative "freeze_hooks"
require_relative "environment"
require_relative "log"
require_relative "views"
require_relative "context"
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

      # Builds a Message and sends it through the configured transport,
      # synchronously -- the calling worker Ractor waits for the send
      # (docs/adr/0012-minimal-built-in-mailer.md accepts that cost; a
      # local relay or a fast HTTPS provider keeps it short). Returns the
      # Message. Invalid input raises InvalidMessageError before anything
      # is sent; a failed send raises DeliveryError.
      #
      #   Monk::Mail.deliver(to: email, subject: "Your login link", text: "Log in: #{link}")
      def deliver(to:, subject:, text: nil, html: nil, reply_to: nil, from: nil)
        raise NotConfiguredError, "call Monk::Mail.configure(url:, from:) before Monk::Mail.deliver" unless config

        from ||= config[:from]
        if from.nil?
          raise InvalidMessageError, "no from: given, and Monk::Mail.configure has no default from: (MAIL_FROM)"
        end

        message = Message.new(from: from, to: to, subject: subject, text: text, html: html, reply_to: reply_to)
        config[:transport].deliver(message)
      end

      # Renders a Monk::Views template to an HTML String for deliver's
      # html: -- e.g. views/mail/magic_link.erb:
      #
      #   html: Monk::Mail.render("mail/magic_link", link: link)
      #
      # The same detached-Context render Monk::Live::Renderer does: no
      # request behind it, so the template sees only its locals, never
      # params or the session. The app's page layout is skipped (layout:
      # false); pass layout: "mail/layout" for an email-specific one.
      # `<%= %>` escapes as usual, which is right for HTML and wrong for a
      # plain-text body -- build text: as a Ruby String instead.
      def render(template, layout: false, **locals)
        ensure_views_frozen!
        String.new(Monk::Context.new({}).render(template, layout: layout, **locals)).freeze
      end

      # Called from Base#freeze! (Seam B), via Monk.freeze_hooks. Freezes
      # the value, not the module, same as Monk::Auth.freeze_registry! --
      # an unfrozen config Hash can't be read from a worker Ractor at all.
      def freeze_registry!
        transport = @config&.fetch(:transport)
        transport.class.prepare! if transport.class.respond_to?(:prepare!)
        @config = Ractor.make_shareable(@config)
      end

      # Test-only: drops the current config. Not part of the app-facing API.
      def reset!
        @config = nil
      end

      private

      # Unfrozen, a render from a worker Ractor dies with an opaque
      # Ractor::IsolationError inside Monk::Views, and one from the main
      # Ractor works by accident and then fails in production -- so both
      # fail here, naming the fix (same check as Monk::Live::Renderer).
      def ensure_views_frozen!
        return if Ractor.shareable?(Monk::Views.registry)

        raise_views_not_frozen
      rescue Ractor::IsolationError
        raise_views_not_frozen
      end

      def raise_views_not_frozen
        raise ViewsNotFrozenError,
          "Monk::Mail.render can't render before views are compiled and frozen -- call Monk.boot(app) " \
          "(or Monk.freeze!) in the main Ractor first"
      end

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
