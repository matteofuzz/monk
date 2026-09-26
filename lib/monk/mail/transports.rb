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
      SMTP = Data.define(:host, :port, :user, :password, :tls, :starttls) do
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
