require "monk"
require "monk/mail"

# Sends email with Monk::Mail.deliver(to:, subject:, text:, html:) from
# any route -- and, with --auth, the magic links config/auth.rb's AppMailer
# delivers. See docs/guides/mail.md. Required from config.ru (not from
# config/auth.rb: bin/websocket_server loads that too, and never sends mail).
Monk::Settings.configure do
  # Where mail goes. Unset in development means log:// (printed to the
  # console, nothing sent); anywhere else an unset one fails the boot.
  # e.g. smtp://user:pass@smtp.provider.com:587 or smtp://localhost:25,
  # provider examples in docs/guides/mail.md.
  optional :mail_url, default: ""
  # The sender of every message, e.g. "My App <no-reply@myapp.com>" --
  # a domain you've verified with your mail provider (SPF, DKIM).
  optional :mail_from, default: "App <no-reply@localhost>"
end

Monk::Mail.configure(url: Monk::Settings[:mail_url], from: Monk::Settings[:mail_from])
