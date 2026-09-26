module Monk
  module Mail
    # Where a Message goes. Each transport is a frozen Data value holding
    # only its settings -- never a connection or client object -- so it
    # can sit in Monk::Mail's boot-frozen config and be read from any
    # worker Ractor; the client is built fresh on every send, inside the
    # Ractor doing the sending, the same pattern as PG::Connection
    # (docs/adr/0012-minimal-built-in-mailer.md).
    module Transports
      # starttls: :always (fail if the server doesn't offer it), :auto (use
      # it if offered) or :never. tls: true is implicit TLS from the first
      # byte (smtps://, usually port 465), where STARTTLS doesn't apply.
      #
      # net-smtp is the app's dependency, not Monk's (a bundled gem since
      # Ruby 3.1, like pg/redis are opt-in): required when an smtp:// URL
      # is configured, so a missing gem fails the boot, not the first send.
      SMTP = Data.define(:host, :port, :user, :password, :tls, :starttls, :open_timeout, :read_timeout) do
        def self.require_library!
          require "net/smtp"
        rescue LoadError
          raise MissingDependencyError,
            "MAIL_URL is smtp:// or smtps://, which needs the net-smtp gem -- a bundled, not default, " \
            "gem since Ruby 3.1. Add `gem \"net-smtp\"` to your Gemfile."
        end

        # Called at boot, in the main Ractor, from Monk::Mail.freeze_registry!.
        # Net::SMTP keeps its AUTH mechanisms ({PLAIN: AuthPlain, ...}) in a
        # class-level Hash, filled once when net/smtp is required; unfrozen,
        # a worker Ractor reading it raises Ractor::IsolationError on every
        # authenticated send. Sealing it is the same move as
        # Monk::Auth.freeze_rqrcode!. The cost: an auth mechanism registered
        # after boot would raise FrozenError -- nothing in net-smtp does that.
        def self.prepare!
          require_library!
          Ractor.make_shareable(Net::SMTP::Authenticator.auth_classes)
        end

        def initialize(host:, port:, user: nil, password: nil, tls: false, starttls: :auto, open_timeout: 5,
                       read_timeout: 10)
          super
        end

        # One connection per message, built here, inside whichever Ractor
        # is sending. Any network, TLS or SMTP-level failure becomes a
        # Monk::Mail::DeliveryError (the original is its #cause), so a
        # caller rescues one class whatever went wrong.
        def deliver(message)
          smtp = Net::SMTP.new(host, port, tls: tls, starttls: starttls == :never ? false : starttls)
          smtp.open_timeout = open_timeout
          smtp.read_timeout = read_timeout
          smtp.start(helo: MIME.domain(message.envelope_from), user: user, secret: password) do |session|
            session.send_message(message.to_mime, message.envelope_from, *message.envelope_to)
          end
          message
        rescue Net::SMTPError, IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError => e
          raise DeliveryError, "SMTP delivery via #{host}:#{port} failed: #{e.class}: #{e.message.strip}"
        end

        # Never print the password -- a transport ends up in logs and
        # exception messages more easily than anyone intends.
        def inspect
          "#<#{self.class.name} #{tls ? "smtps" : "smtp"}://#{"#{user}:***@" if user}#{host}:#{port} " \
            "starttls=#{starttls}>"
        end
        alias_method :to_s, :inspect
      end

      # Writes each message to Monk::Log instead of sending it: the
      # development default when MAIL_URL is unset, and an explicit
      # log:// anywhere else. One line per message in log/<env>.log (the
      # text body escaped with #inspect so it stays one line; the HTML
      # only by size), plus, in development only, the whole readable
      # message on $stdout -- where a developer is looking, and where a
      # magic link gets clicked. Same stdout posture as Base#log_request
      # and Monk::Auth.log_dev_link.
      Log = Data.define do
        def deliver(message)
          Monk::Log.info("[mail] #{summary(message)}")
          if Monk.env.development?
            $stdout.puts(readable(message))
            $stdout.flush
          end
          message
        end

        private

        def summary(message)
          fields = [
            "from=#{message.from.inspect}",
            "to=#{message.to.join(", ").inspect}",
            ("reply_to=#{message.reply_to.inspect}" if message.reply_to),
            "subject=#{message.subject.inspect}",
            ("text=#{message.text.inspect}" if message.text),
            ("html=#{message.html.bytesize} bytes" if message.html),
          ]
          fields.compact.join(" ")
        end

        def readable(message)
          lines = [
            "[mail] ----------------------------------------",
            "From: #{message.from}",
            "To: #{message.to.join(", ")}",
            ("Reply-To: #{message.reply_to}" if message.reply_to),
            "Subject: #{message.subject}",
          ]
          lines += ["", "--- text ---", message.text] if message.text
          lines += ["", "--- html ---", message.html] if message.html
          (lines.compact + ["[mail] ----------------------------------------"]).join("\n")
        end
      end
    end
  end
end
