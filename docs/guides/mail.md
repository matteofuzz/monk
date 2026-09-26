# Sending email — `Monk::Mail`

Text and/or HTML email over SMTP, opt-in (`require "monk"` never loads
it). Monk builds the MIME itself and sends from inside whichever worker
Ractor serves the request: the `mail` gem, and so Action Mailer, raises
`Ractor::IsolationError` there, which is why Monk ships its own
(`docs/adr/0012-minimal-built-in-mailer.md`). Deliberately small: no
attachments, no inline images, no BCC lists, no bulk sending.

```ruby
# config/mail.rb
require "monk/mail"

Monk::Mail.configure(url: ENV["MAIL_URL"], from: ENV["MAIL_FROM"])
```

```ruby
post("/contact") do
  Monk::Mail.deliver(to: "team@app.example", subject: "New message", text: params[:body])
  json(ok: true)
end
```

## `MAIL_URL`

One URL picks the transport. It's parsed by `configure`, so a malformed
one fails the boot, not the first send.

| `MAIL_URL` | What it does |
|---|---|
| `smtp://user:pass@smtp.example.com:587` | SMTP with AUTH. Port 587 by default. **STARTTLS is required** when credentials are set, so the password never crosses the wire in clear |
| `smtp://localhost:25` | A local relay (Postfix, nullmailer, a sidecar container), no AUTH. STARTTLS is used if the relay offers it |
| `smtp://…?starttls=always\|auto\|never` | Overrides either STARTTLS default |
| `smtps://user:pass@smtp.example.com` | TLS from the first byte. Port 465 by default |
| `log://` | Doesn't send. Writes each message to `log/<env>.log`, and in development also prints it to stdout |
| unset or empty | `log://` in development; `Monk::Mail::MissingMailUrlError` at boot everywhere else |

Percent-encode a user or password containing `@`, `:` or `/`
(`p%40ss` for `p@ss`). The password is never shown in error messages or
in the transport's `inspect`.

`smtp://` and `smtps://` need the **`net-smtp`** gem, a bundled rather
than default gem since Ruby 3.1. Add it to your Gemfile; without it the
boot fails with `Monk::Mail::MissingDependencyError`:

```ruby
gem "net-smtp"
```

`from:` is the default sender (`"App <no-reply@app.example>"` or a bare
address). It's optional, since every `deliver` can pass its own.

## `Monk::Mail.deliver`

```ruby
Monk::Mail.deliver(
  to: ["ann@example.com", "Bob <bob@example.com>"], # a String or an Array
  subject: "Your login link",
  text: "Log in: #{link}",
  html: "<p><a href=\"#{link}\">Log in</a></p>",      # optional; with text: it's multipart/alternative
  reply_to: "support@app.example",                     # optional
  from: "Support <support@app.example>",               # optional, overrides configure's from:
)
```

It returns the `Monk::Mail::Message` it sent. At least one of `text:` or
`html:` is required. Non-ASCII subjects, names and bodies are fine; every
part goes out as UTF-8.

It raises:

- **`Monk::Mail::InvalidMessageError`** (an `ArgumentError`) for bad input,
  before anything is sent: a missing field, a non-String, invalid UTF-8,
  or a **line break in any header field**. That last one matters when an
  address comes from a form: a CR/LF would let the user add headers of
  their own, like a `Bcc:`. It's refused, not stripped.
- **`Monk::Mail::DeliveryError`** when the send fails: connection refused,
  timeout, a TLS or certificate error, or the server rejecting AUTH or a
  recipient. The underlying exception is its `cause`.
- **`Monk::Mail::NotConfiguredError`** if `configure` was never called.

### A send blocks the worker

`deliver` is synchronous: the worker Ractor serving the request waits for
the whole SMTP conversation, and Monk has no job queue. SMTP timeouts are
5s to connect and 10s per read. Two ways to keep it short:

- **A local relay** (`smtp://localhost:25`). Handing the message to a relay
  on the same host takes about a millisecond; the relay queues it, retries,
  and talks to your provider on its own time. The cost: one more process,
  and a message the relay later fails to deliver only shows up in the
  relay's logs, never as a `DeliveryError`.
- **A provider close to your servers.** A remote SMTP send is several
  round-trips, so latency adds up.

## With `Monk::Auth`

`Monk::Auth.deliver_link` calls a `deliver:` callable when one is
configured. Point it at `Monk::Mail`, built as a module constant so it's
`Ractor.shareable?` (see [`auth.md`](auth.md)):

```ruby
# config/auth.rb
module AppMailer
  DELIVER = lambda do |email:, link:, token:|
    Monk::Mail.deliver(to: email, subject: "Your login link", text: "Log in: #{link}")
  end
end

Monk::Auth.configure(..., deliver: AppMailer::DELIVER)
```

## In tests

Set `MAIL_URL=log://` for the test environment: nothing is sent, and each
message is one line in `log/test.log`. An unset `MAIL_URL` outside
development fails the boot on purpose.

## Choosing where mail goes

- **On a VPS**, port 587 is usually open from day one, so SMTP to any
  provider works. Hetzner blocks 25 and 465 for new accounts, which
  doesn't matter for a relay on 587.
- **On a PaaS**, outbound SMTP is often blocked (Railway below Pro,
  Render's free tier, Fly by default). HTTPS provider presets
  (`brevo://`, `lettermint://`, `resend://`) are planned for exactly that
  case; the provider comparison behind them is in
  [`../mail-providers.md`](../mail-providers.md).
- **Deliverability** is set up at your provider and in DNS, not in Monk:
  verify the sending domain with SPF, DKIM and DMARC. For a magic link, a
  message in spam is as bad as one never sent.
- **Don't run your own MTA delivering straight to recipients** (port 25
  to Gmail's servers). VPS IP ranges have poor reputation, and keeping
  that working is an ongoing job. A local relay that forwards to a
  provider is fine; it's the direct-to-recipient part that isn't.
