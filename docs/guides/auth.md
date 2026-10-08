# Auth & sessions — `Monk::Auth`

Passwordless token auth, opt-in (`require "monk"` never loads it) and built
on `Monk::Persistence::Pg` — not just an integration, a hard dependency:
`Monk::Auth::LoginToken`/`Session` are themselves `Pg::Model` subclasses, so
`require "monk/auth"` always needs the `pg` gem and a registered Postgres
connection, whether or not your app uses persistence for anything else.
`monk add auth` sets all of it up in one step (adding `postgres` and `mail`
first if the app lacks them): `config/auth.rb`, a migration creating the
tables below, the mailer sending the link, a login page, and the routes as
a commented example to turn on (`auth-routes` in `app/routes/auth.rb`) — see
[`scaffolding.md`](scaffolding.md).

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
and `sessions` (multi-use, long-lived). `monk add auth` writes a
migration for both; otherwise create them yourself the same way persistence
tables aren't generated either — schema in [`design/auth-sessions.md`](../design/auth-sessions.md).

Both an `Authorization: Bearer <token>` header and a `session_token`
cookie work identically via `current_subject`/`require_user!`. For
browsers, `set_session_cookie(session)` sets that cookie (plus a readable
`csrf_token` one) instead of returning the token as JSON, and
`require_csrf!` guards state-changing routes — a no-op for Bearer
requests, since a forged cross-origin request has no way to set that
header. `log_out!` ends the current session (revokes it, Bearer or cookie,
and clears the cookies; call `require_csrf!` first on a cookie route).
`Monk::Auth.revoke(token)` / `.revoke_all(subject)` invalidate
sessions; `.sweep!` deletes expired rows. Full design and phase-by-phase
build: [`design/auth-sessions.md`](../design/auth-sessions.md) / `docs/history/plan-auth.md`.

### Sending the magic link

`Monk::Auth.request_login` returns a raw token and nothing else. Monk
doesn't define the callback route, but it knows its path:
`Monk::Auth.configure(callback_path:)`, `"/auth/callback"` by default, so
your route is `get("/auth/callback/:token")`. `Monk::Auth.login_link(token)`
builds the link from it. Sending is a separate concern, which `Monk::Mail`
covers ([`mail.md`](mail.md)). Your login route hands the link, with the
token, to `Monk::Auth.deliver_link`:

```ruby
post("/auth/request") do
  token = Monk::Auth.request_login(params[:email], redirect_to: "/")
  Monk::Auth.deliver_link(email: params[:email], link: Monk::Auth.login_link(token), token: token)
  json(ok: true)
end
```

`login_link` starts from a configured origin, `Monk::Settings[:public_url]`,
declared in `config/settings.rb` (every `monk new` app has this, with or
without auth — `Monk::Live`'s `live_ws_url` and `WS_ALLOWED_ORIGINS` read the
same setting, see `docs/guides/live.md`). If you build a link yourself,
start from it too, never from request headers like
`X-Forwarded-Proto` or `Host`. Those come from
whoever is making the request, so a direct client (not just a trusted proxy)
can set them; harmless while the only thing reading them is a dev-only
console log, but not once a real delivery goes out to whatever address they
typed in.

`deliver_link` picks, in order:

1. **The configured `deliver:` callable**, if `Monk::Auth.configure` was
   given one — `deliver.call(email:, link:, token:)`. This is where email
   plugs in, usually a one-line call to `Monk::Mail.deliver` (example in
   [`mail.md`](mail.md#with-monkauth)), or any other channel such as SMS.
   Like a route block, it has to be `Ractor.shareable?`, so build
   it as a module constant (`AuthMailer::MAGIC_LINK = ->(email:, link:, token:)
   { ... }`, in `app/mailers/app_mailer.rb`), not inline in
   `config/auth.rb` — self at a script's top level isn't shareable, the
   same rule `Monk::Live.authorize` blocks follow. `config/auth.rb`
   requires that file itself (`require_relative "../app/mailers/app_mailer"`),
   since `configure` checks `deliver:` right away, before
   `config/load.rb` loads `app/`.
2. **`Monk::Auth.log_dev_link`**, only if no `deliver:` is configured and
   `Monk.env.development?` — prints the link to stdout and
   `log/development.log`, plus a scannable QR code if the app's own
   Gemfile has `rqrcode`, for testing from a second device with no mail
   setup at all.
3. **Otherwise raises** `Monk::MissingAuthDeliveryError`. An app that
   forgot to configure `deliver:` finds out the first time someone requests
   a login, not later from a user who never got their email.

### Sending the magic link from a job

With [background jobs](jobs.md), the login request doesn't have to wait
for the email to go out. Move the whole request into a job, not just the
send: the job creates the token and sends the link, so the raw token only
ever exists in memory and in the email. Monk ships this job as
`Monk::Auth::SendLoginLink`, defined once `monk/auth` and `monk/jobs` are
both loaded:

```ruby
post("/auth/request") do
  # your per-email rate limit first
  Monk::Auth::SendLoginLink.enqueue(params[:email]) # or (email, redirect_to)
  json(sent: true)
end
```

It runs on the `mailers` queue with 3 attempts (a login email minutes late
is worse than none), never retries an `InvalidRedirectError`, and sends
`Monk::Auth.login_link(token)` through your `deliver:`, synchronously, in
the job. Subclass it to change the queue or the retries.

- **Why not `deliver:` calling `Monk::Mail.deliver_later`?** That would
  store the link, token included, in the job queue until it's sent. A
  second or less normally, but minutes while the mail relay is down, and
  indefinitely in a failed job. `Monk::Auth` stores only token hashes so
  that reading the database is never enough to log in as someone, and a
  queued link would undo that for as long as it's valid. With the job
  above, the queue holds only the email address.
- **`login_ttl` starts when the email is sent,** not when it was requested.
  A retry after a failed send creates a fresh token, and the unsent one
  expires unused.
- **Check `redirect_to` in the route** before enqueueing, if you pass one.
  In the job, an invalid one fails at once (`never_retry`), but the user
  never hears about it.
- **Failures surface in the job process, not the request.** The route can
  only say "if that address is registered, a link is on its way", which
  is the usual reply for a login form anyway.
- **In development**, the dev link and its QR code print on `bin/jobs`'s
  console, not `bin/server`'s.

The reasoning, and the options rejected, are in
[`docs/adr/0014-mail-from-jobs-and-login-links-created-in-the-job.md`](../adr/0014-mail-from-jobs-and-login-links-created-in-the-job.md).

### Secure cookies

Both cookies carry the `Secure` flag by default, so browsers only send them
over HTTPS. Over plain `http://` (a dev server, a second device on the LAN)
Safari — Private Browsing especially — silently drops a `Secure` cookie, and
login appears to do nothing. Pass `secure: false` to
`Monk::Auth.configure` to omit the flag; `monk add auth`'s `config/auth.rb` does
this in development (`secure: !Monk.env.development?`) and keeps it on
everywhere else. Don't set it to `false` in production.
