# Sending email — `Monk::Mail`

Text and/or HTML email over SMTP, opt-in (`require "monk"` never loads
it). Monk builds the MIME itself and sends from inside whichever worker
Ractor serves the request: the `mail` gem, and so Action Mailer, raises
`Ractor::IsolationError` there, which is why Monk ships its own
(`docs/adr/0012-minimal-built-in-mailer.md`). Deliberately small: no
attachments, no inline images, no BCC lists, no bulk sending.

```ruby
# config/mail.rb -- `monk new my_app --mail` writes this (as Settings) for you
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

### Provider examples

Every transactional provider offers an SMTP relay, so no provider-specific
code is needed. The first three are the ones recommended in
[`../mail-providers.md`](../mail-providers.md) (EU-hosted Brevo and
Lettermint, worldwide Resend); hosts and credential formats were checked
against each provider's docs on 2026-09-26.

```sh
# Brevo (FR, EU-hosted). The login looks like an address: encode its @ as %40.
# The password is an SMTP key from the SMTP & API page, not the API key.
MAIL_URL=smtp://8f1a2b001%40smtp-brevo.com:SMTP_KEY@smtp-relay.brevo.com:587

# Lettermint (NL, own EU infrastructure). The user is literally "lettermint".
MAIL_URL=smtp://lettermint:PROJECT_API_TOKEN@smtp.lettermint.co:587

# Resend (US, not EU-resident). The user is literally "resend".
MAIL_URL=smtp://resend:RESEND_API_KEY@smtp.resend.com:587

# Postmark (US). The server API token is both user and password.
MAIL_URL=smtp://SERVER_TOKEN:SERVER_TOKEN@smtp.postmarkapp.com:587

# Scaleway TEM (FR). The user is the project ID.
MAIL_URL=smtp://PROJECT_ID:API_SECRET_KEY@smtp.tem.scaleway.com:587

# Amazon SES, EU region. Use SES SMTP credentials, not IAM access keys;
# an SES password can contain "/", which must be encoded as %2F.
MAIL_URL=smtp://SES_SMTP_USER:SES_SMTP_PASSWORD@email-smtp.eu-west-1.amazonaws.com:587

# Mailgun, EU region. Per-domain SMTP credentials; encode the login's @.
MAIL_URL=smtp://postmaster%40mg.example.com:SMTP_PASSWORD@smtp.eu.mailgun.org:587
```

All of these accept 587 with STARTTLS, which the URL requires by default
because credentials are set. Most also listen on 2525 (Brevo, Lettermint,
Postmark, Mailgun; Resend uses 2587), useful when a network blocks 587:
change only the port. Verify your sending domain with the provider
(SPF, DKIM) before going live.

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

### HTML from a template

`Monk::Mail.render` turns a view into the `html:` String:

```erb
<%# app/views/mail/magic_link.erb %>
<p><a href="<%= locals[:link] %>">Log in</a></p>
```

```ruby
Monk::Mail.deliver(to: email, subject: "Your login link",
  text: "Log in: #{link}", html: Monk::Mail.render("mail/magic_link", link: link))
```

Templates are compiled at boot with the rest of the views, and rendered
without a request behind them: they see only their `locals`, never
`params` or the session, the same as `Monk::Live` partials. The app's
page layout is skipped; pass `layout: "mail/layout"` for an email one.
`<%= %>` HTML-escapes, which is right for the HTML part and wrong for
plain text, so build `text:` as a Ruby String. Calling `render` before
`Monk.boot` raises `Monk::Mail::ViewsNotFrozenError`.

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
the whole SMTP conversation. SMTP timeouts are 5s to connect and 10s per
read. With background jobs, send from a job instead (next section).
Without them, two ways to keep it short:

- **A local relay** (`smtp://localhost:25`). Handing the message to a relay
  on the same host takes about a millisecond; the relay queues it, retries,
  and talks to your provider on its own time. The cost: one more process,
  and a message the relay later fails to deliver only shows up in the
  relay's logs, never as a `DeliveryError`.
- **A provider close to your servers.** A remote SMTP send is several
  round-trips, so latency adds up.

### Sending from a job: `deliver_later`

With [`Monk::Jobs`](jobs.md) set up, `deliver_later` hands the send to the
job process (`bin/jobs`), so the request doesn't wait for SMTP at all. It's
defined as soon as both `monk/mail` and `monk/jobs` are loaded, in either
order, so there's nothing to require for it:

```ruby
Monk::Mail.deliver_later(to: order[:email], subject: "Your receipt",
  text: receipt_text, html: Monk::Mail.render("mail/receipt", order: order))
```

- **The same arguments as `deliver`**, plus `wait:`/`at:` to send later,
  and `conn:` to enqueue inside your own transaction, so the email is only
  sent if your writes commit ([`jobs.md`](jobs.md), "Inside the app's own
  transaction"). It returns the job's id, not the sent message.
- **Checked when you call it.** The message is built before anything is
  queued, so bad input raises `InvalidMessageError` right there, as with
  `deliver`. A missing `from:` is filled in from `configure` at that moment.
- **Render HTML first**, with `Monk::Mail.render`, as above. The job stores
  the finished message and only sends it, so the job process doesn't need
  your templates, and a message queued before a deploy sends what was
  rendered then.
- **Retries:** a temporary failure (the relay unreachable, a 4xx "try
  later", TLS, a timeout) is retried with the queue's usual backoff. A
  refusal the server made final (a 5xx such as "no such mailbox", or
  refused credentials) fails the job at once as
  `Monk::Mail::PermanentDeliveryError`, a `DeliveryError`. Failed jobs
  stay in the queue until retried or discarded ([`jobs.md`](jobs.md),
  "When a job fails"), so after fixing a bad `MAIL_URL`,
  `Monk::Jobs.retry_failed(id)` resends.
- **The `mailers` queue.** Mail jobs run on it, and `monk new` sets
  `JOBS_QUEUES=mailers,default` so they're served before other work. Once
  the app has slow jobs, run a separate `bin/jobs` just for `mailers`
  (`JOBS_QUEUES=mailers`), so an email never waits behind them.
- **Delivery is at-least-once.** A job process killed mid-send can send the
  same email twice. That's rare, and usually harmless for mail, but it's
  why `deliver_later` isn't for anything that must go out exactly once.

## With `Monk::Auth`

`monk new --auth` wires this for you: `config/mail.rb`,
`app/mailers/app_mailer.rb`, `app/views/mail/magic_link.erb`,
`gem "net-smtp"`, and a `deliver:` in `config/auth.rb`. By hand,
`Monk::Auth.deliver_link` calls a `deliver:` callable when one is
configured; point it at `Monk::Mail`, built as a module constant so it's
`Ractor.shareable?` (see [`auth.md`](auth.md)). A mailer is app code, so
it lives in `app/mailers/` with the app's other emails:

```ruby
# app/mailers/app_mailer.rb
module AppMailer
  MAGIC_LINK = lambda do |email:, link:, token:|
    Monk::Auth.log_dev_link(link, subject: email) # development only: console line + QR code
    Monk::Mail.deliver(to: email, subject: "Your login link",
      text: "Log in: #{link}", html: Monk::Mail.render("mail/magic_link", link: link))
  end
end
```

```ruby
# config/auth.rb
require_relative "../app/mailers/app_mailer" # configure checks deliver: right away

Monk::Auth.configure(..., deliver: AppMailer::MAGIC_LINK)
```

Require `config/mail.rb` from `config/load.rb`, not from `config/auth.rb`:
`bin/websocket_server` loads `config/auth.rb` too, never sends mail, and
shouldn't need `MAIL_URL` to boot. That's why the mailer touches
`Monk::Mail` only inside the lambda.

**Don't point `deliver:` at `deliver_later`.** The job would store the
login link, a working token included, in the queue until it's sent. That
undoes the reason `Monk::Auth` stores only token hashes: that reading the
database isn't enough to log in as someone. To send login links from a job,
move the whole login request into one, so the token is created and sent
inside the job and never stored. `monk new --auth --jobs` scaffolds it as
`app/jobs/send_login_link.rb`; see [`auth.md`](auth.md), "Sending the magic
link from a job".

## In tests

Set `MAIL_URL=log://` for the test environment: nothing is sent, and each
message is one line in `log/test.log`. An unset `MAIL_URL` outside
development fails the boot on purpose.

Mail sent with `deliver_later` is queued, not sent, until the job runs: run
it in the test with `Monk::Jobs.drain!` ([`jobs.md`](jobs.md), "Testing
jobs"), then check `log/test.log`.

## Choosing where mail goes

- **On a VPS**, port 587 is usually open from day one, so SMTP to any
  provider works. Hetzner blocks 25 and 465 for new accounts, which
  doesn't matter for a relay on 587.
- **On a PaaS**, outbound SMTP is often blocked (Railway below Pro,
  Render's free tier, Fly by default). `Monk::Mail` only speaks SMTP, so
  there you need a plan that allows it, a support request, or a different
  host. The provider comparison, including their HTTPS APIs, is in
  [`../mail-providers.md`](../mail-providers.md).
- **Deliverability** is set up at your provider and in DNS, not in Monk:
  verify the sending domain with SPF, DKIM and DMARC. For a magic link, a
  message in spam is as bad as one never sent.
- **Don't run your own MTA delivering straight to recipients** (port 25
  to Gmail's servers). VPS IP ranges have poor reputation, and keeping
  that working is an ongoing job. A local relay that forwards to a
  provider is fine; it's the direct-to-recipient part that isn't.
