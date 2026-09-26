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
      # development default when MAIL_URL is unset.
      Log = Data.define
    end
  end
end
