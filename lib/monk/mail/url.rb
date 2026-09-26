require "uri"

module Monk
  module Mail
    # MAIL_URL -> a transport value. Runs once, from Monk::Mail.configure
    # in the main Ractor at boot, so a malformed URL fails the boot rather
    # than the first send (docs/adr/0003-boot-time-fail-fast-shareability.md's
    # posture). Error messages redact the password: the URL is a secret.
    module URL
      SUPPORTED = "smtp://, smtps://, log://".freeze
      STARTTLS_MODES = %w[auto always never].freeze

      module_function

      def parse(url)
        uri = URI.parse(url)
        case uri.scheme&.downcase
        when "log" then Transports::Log.new
        when "smtp" then smtp(uri, url, tls: false)
        when "smtps" then smtp(uri, url, tls: true)
        else invalid!(url, "unsupported scheme #{uri.scheme.inspect}; supported: #{SUPPORTED}")
        end
      rescue URI::InvalidURIError
        invalid!(url, "not a valid URL; expected e.g. smtp://user:pass@smtp.example.com:587")
      end

      def smtp(uri, url, tls:)
        invalid!(url, "missing host") if uri.host.nil? || uri.host.empty?

        user = decode(uri.user)
        Transports::SMTP.new(
          host: uri.host,
          port: uri.port || (tls ? 465 : 587),
          user: user,
          password: decode(uri.password),
          tls: tls,
          starttls: starttls(uri, url, tls: tls, credentials: !user.nil?),
        )
      end

      # Default :always with credentials (a stripped STARTTLS would
      # otherwise send the password in clear), :auto without (a local
      # relay usually has no TLS set up).
      def starttls(uri, url, tls:, credentials:)
        options = URI.decode_www_form(uri.query || "").to_h
        unknown = options.keys - ["starttls"]
        invalid!(url, "unknown option(s) #{unknown.join(", ")}; the only one is starttls=") if unknown.any?

        mode = options["starttls"]
        if tls
          invalid!(url, "starttls= doesn't apply to smtps://, which is TLS from the start") if mode
          return :never
        end
        return credentials ? :always : :auto if mode.nil?

        invalid!(url, "starttls= must be one of #{STARTTLS_MODES.join(", ")}") unless STARTTLS_MODES.include?(mode)
        mode.to_sym
      end

      def decode(component)
        return nil if component.nil? || component.empty?

        URI.decode_uri_component(component)
      end

      def invalid!(url, reason)
        raise InvalidMailUrlError, "MAIL_URL #{redact(url).inspect}: #{reason}"
      end

      def redact(url)
        url.to_s.sub(%r{(://[^:/@]*:)[^@/]*@}, '\1***@')
      end
    end
  end
end
