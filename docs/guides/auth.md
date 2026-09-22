# Auth & sessions — `Monk::Auth`

Passwordless token auth, opt-in (`require "monk"` never loads it) and built
on `Monk::Persistence::Pg` — not just an integration, a hard dependency:
`Monk::Auth::LoginToken`/`Session` are themselves `Pg::Model` subclasses, so
`require "monk/auth"` always needs the `pg` gem and a registered Postgres
connection, whether or not your app uses persistence for anything else.
`monk new my_app --auth` scaffolds all of it in one step (implying
`--postgres`): `config/auth.rb` and a migration creating the tables below —
see [`scaffolding.md`](scaffolding.md).

```ruby
require "monk/auth"

Monk::Auth.configure(
  db_name: :main, secret: ENV.fetch("AUTH_SECRET"),
  login_ttl: 600, session_ttl: 1_209_600, redirect_allowlist: ["/dashboard"],
)

class App < Monk::Base
  post("/auth/request") { json(token: Monk::Auth.request_login(params[:email])) } # send this token yourself -- see "Sending the magic link" below

  get("/auth/callback/:token") do
    session = Monk::Auth.redeem(params[:token])
    halt(401) unless session
    json(token: session[:token], expires_at: session[:expires_at])
  end

  get("/me") { json(subject: require_user!) } # halts 401 automatically if unauthenticated
end
```

Two Postgres tables back this — `login_tokens` (single-use, short-lived)
and `sessions` (multi-use, long-lived). `monk new --auth` scaffolds a
migration for both; otherwise create them yourself the same way persistence
tables aren't generated either — schema in [`design/auth-sessions.md`](../design/auth-sessions.md).

Both an `Authorization: Bearer <token>` header and a `session_token`
cookie work identically via `current_subject`/`require_user!`. For
browsers, `set_session_cookie(session)` sets that cookie (plus a readable
`csrf_token` one) instead of returning the token as JSON, and
`require_csrf!` guards state-changing routes — a no-op for Bearer
requests, since a forged cross-origin request has no way to set that
header. `Monk::Auth.revoke(token)` / `.revoke_all(subject)` invalidate
sessions; `.sweep!` deletes expired rows. Full design and phase-by-phase
build: [`design/auth-sessions.md`](../design/auth-sessions.md) / `docs/history/plan-auth.md`.

### Sending the magic link

`Monk::Auth.request_login` returns a raw token and nothing else — Monk
doesn't own SMTP or any provider's API, and stays out of routing, so it
can't build the callback URL either (`docs/design/auth-sessions.md`, "Email
delivery stays outside the framework"). Your login route builds the link
and hands it, with the token, to `Monk::Auth.deliver_link`:

```ruby
post("/auth/request") do
  token = Monk::Auth.request_login(params[:email], redirect_to: "/")
  link = "#{Monk::Settings[:public_url]}/auth/callback/#{token}"
  Monk::Auth.deliver_link(email: params[:email], link: link, token: token)
  json(ok: true)
end
```

Build `link` from a configured origin — `Monk::Settings[:public_url]` above,
declared once in `config/auth.rb` (`monk new --auth` scaffolds this) — never
from request headers like `X-Forwarded-Proto` or `Host`. Those come from
whoever is making the request, so a direct client (not just a trusted proxy)
can set them; harmless while the only thing reading them is a dev-only
console log, but not once a real delivery goes out to whatever address they
typed in.

`deliver_link` picks, in order:

1. **The configured `deliver:` callable**, if `Monk::Auth.configure` was
   given one — `deliver.call(email:, link:, token:)`. This is where a real
   mailer or provider (SMTP, SendGrid, Postmark, ...) plugs in; Monk never
   ships one. Like a route block, it has to be `Ractor.shareable?`, so build
   it as a module constant (`AppMailer::DELIVER = ->(email:, link:, token:)
   { ... }`), not inline in `config/auth.rb` — self at a script's top level
   isn't shareable, the same rule `Monk::Live.authorize` blocks follow.
2. **`Monk::Auth.log_dev_link`**, only if no `deliver:` is configured and
   `Monk.env.development?` — prints the link to stdout and
   `log/development.log`, plus a scannable QR code if the app's own
   Gemfile has `rqrcode`, for testing from a second device with no mail
   setup at all.
3. **Otherwise raises** `Monk::MissingAuthDeliveryError`. An app that
   forgot to configure `deliver:` finds out the first time someone requests
   a login, not later from a user who never got their email.

### Secure cookies

Both cookies carry the `Secure` flag by default, so browsers only send them
over HTTPS. Over plain `http://` (a dev server, a second device on the LAN)
Safari — Private Browsing especially — silently drops a `Secure` cookie, and
login appears to do nothing. Pass `secure: false` to
`Monk::Auth.configure` to omit the flag; the `monk new --auth` scaffold does
this in development (`secure: !Monk.env.development?`) and keeps it on
everywhere else. Don't set it to `false` in production.
