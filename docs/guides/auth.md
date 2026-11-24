# Auth & sessions — `Monk::Auth`

Passwordless token auth, opt-in (`require "monk"` never loads it) and built
on `Monk::Persistence::Pg` — not just an integration, a hard dependency:
`Monk::Auth::LoginToken`/`Session` are themselves `Pg::Model` subclasses, so
`require "monk/auth"` always needs the `pg` gem and a registered Postgres
connection, whether or not your app uses persistence for anything else.
`monk add auth` sets all of it up in one step (adding `postgres` and `mail`
first if the app lacks them): `config/auth.rb`, migrations creating the
tables below, the mailer sending the link, a login page, and the routes as
a commented example to turn on (`auth-routes` in `app/routes/auth.rb`) — see
[`scaffolding.md`](scaffolding.md).

```ruby
# config/auth.rb
require "monk/auth"

Monk::Auth.configure(
  db_name: :primary, secret: ENV.fetch("AUTH_SECRET"),
  login_ttl: 600, session_ttl: 1_209_600, redirect_allowlist: ["/dashboard", %r{/invite/\w+}],
  deliver: AuthMailer::MAGIC_LINK, # sends the link and the code: "Sending the magic link" below
)
```

```ruby
# app/routes/auth.rb, as `monk add auth` writes it (shortened)
class App
  post("/auth/request") do
    email = params[:email].to_s.strip.downcase
    halt(429) unless Monk::Auth.allow_login_request?(email) # "Rate-limiting login emails"
    login = Monk::Auth.request_login(email) # { token:, code: }
    Monk::Auth.deliver_link(email: email, link: Monk::Auth.login_link(login[:token]), token: login[:token],
      code: login[:code])
    @email = email
    render "auth/login" # now asks for the code; the token and code go only in the email
  end

  get("/auth/callback/:token") do # the link in the email
    session = Monk::Auth.redeem(params[:token]) || halt(401, "This link has expired or was already used.")
    set_session_cookie(session)
    redirect(session[:redirect_to] || "/")
  end

  post("/auth/code") do # the code from the email, typed on the login page
    session = Monk::Auth.redeem_code(params[:email].to_s, params[:code].to_s) || halt(422, render("auth/login"))
    set_session_cookie(session)
    redirect(session[:redirect_to] || "/")
  end

  get("/me") { json(email: require_user!) } # 401 unless logged in
end
```

Never send the token or the code back in the response: whoever asked for
them could then log in as any address they typed.

Three Postgres tables back this — `login_tokens` (single-use, short-lived),
`sessions` (multi-use, long-lived, indexed by `subject`) and
`login_requests` (the [rate limit](#rate-limiting-login-emails)).
`monk add auth` writes migrations for all three; without it, create them
yourself from the schema in [`design/auth-sessions.md`](../design/auth-sessions.md).

Both an `Authorization: Bearer <token>` header and a `session_token`
cookie work identically via `current_subject`/`require_user!`. For
browsers, `set_session_cookie(session)` sets that cookie (plus a readable
`csrf_token` one) instead of returning the token as JSON, and
`require_csrf!` guards state-changing routes — a no-op for Bearer
requests, since a forged cross-origin request has no way to set that
header. A form sends the token with `<%= csrf_field %>`, `fetch` with the
`x-csrf-token` header (the cookie's value; see [`forms.md`](forms.md)).
`log_out!` ends the current session (revokes it, Bearer or cookie,
and clears the cookies; call `require_csrf!` first on a cookie route).

The `csrf_token` cookie is signed with `AUTH_SECRET`, sessions aren't:
after the secret changes (a new one, or a backup restored on a server with
another) sessions still work, and Monk replaces a `csrf_token` cookie that
no longer matches on the next signed-in request, a 403 from
`require_csrf!` included. A `fetch` that got that 403 succeeds when it
tries again. Keep `AUTH_SECRET` with your backups anyway: sessions survive
without it, but nothing else signed with it does.
`Monk::Auth.revoke(token)` / `.revoke_all(subject)` invalidate
sessions; `.sweep!` deletes expired rows ([Cleaning up](#cleaning-up-expired-rows)).
A session in use is renewed ([Sessions renewed by use](#sessions-renewed-by-use)).
The design: [`design/auth-sessions.md`](../design/auth-sessions.md).

## Sending the magic link

`Monk::Auth.request_login(email, redirect_to:)` returns `{ token:, code: }`:
a raw token for the link, and the 6-digit code beside it
([Signing in with a code](#signing-in-with-a-code)). The address is
stripped and downcased. Monk doesn't define the callback route, but it
knows its path:
`Monk::Auth.configure(callback_path:)`, `"/auth/callback"` by default, so
your route is `get("/auth/callback/:token")`. `Monk::Auth.login_link(token)`
builds the link from it. Sending is a separate concern, which `Monk::Mail`
covers ([`mail.md`](mail.md)). Your login route hands the link, with the
token, to `Monk::Auth.deliver_link`:

```ruby
post("/auth/request") do
  login = Monk::Auth.request_login(params[:email], redirect_to: "/")
  Monk::Auth.deliver_link(email: params[:email], link: Monk::Auth.login_link(login[:token]),
    token: login[:token], code: login[:code])
  json(ok: true)
end
```

`login_link` starts from a configured origin, `Monk::Settings[:public_url]`,
declared in `config/settings.rb` (every `monk new` app has this, with or
without auth — `Monk::Live`'s `live_ws_url` and the WebSocket's allowed
origins read the same setting, see [`live.md`](live.md)). Outside
development and test, boot refuses it on `http://` or a placeholder host
like `example.com`, and refuses a placeholder or short `AUTH_SECRET`
([`settings.md`](settings.md#values-refused-at-boot)). If you build a link yourself,
start from it too, never from request headers like
`X-Forwarded-Proto` or `Host`. Those come from
whoever is making the request, so a direct client (not just a trusted proxy)
can set them; harmless while the only thing reading them is a dev-only
console log, but not once a real delivery goes out to whatever address they
typed in.

`deliver_link` picks, in order:

1. **The configured `deliver:` callable**, if `Monk::Auth.configure` was
   given one — `deliver.call(email:, link:, token:, redirect_to:, code:)`,
   always with all five keywords (`redirect_to:` lets the mail say where
   the link leads, an invitation, say; take what you don't use with
   `**`). This is where email
   plugs in, usually a one-line call to `Monk::Mail.deliver` (example in
   [`mail.md`](mail.md#with-monkauth)), or any other channel such as SMS.
   Like a route block, it has to be `Ractor.shareable?`, so build
   it as a module constant (`AuthMailer::MAGIC_LINK = ->(email:, link:, code:, **)
   { ... }`, in `app/mailers/auth_mailer.rb`), not inline in
   `config/auth.rb` — self at a script's top level isn't shareable, the
   same rule `Monk::Live.authorize` blocks follow. `config/auth.rb`
   requires that file itself (`require_relative "../app/mailers/auth_mailer"`),
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

## Signing in with a code

A magic link leaves the page the person is on: to the mail app, then to
whatever browser the mail app opens. On a phone that's often not the one
they started in: a page opened in a chat app's built-in browser stays
signed out, and the installed app on an iPhone can't receive a link at
all (Mail opens it in Safari). So every login token also has a 6-digit
code, sent beside the link, which the person types on the page that asked
for it.

- **One token, two ways to redeem it.** `Monk::Auth.redeem_code(email,
  code)` returns a session like `redeem`, or nil. Redeeming the link or the
  code uses the token: the other stops working. Same `login_ttl`.
- **Only the address's newest token counts**, so "Send a new code"
  retires the previous one.
- **Guessing is limited.** A wrong code counts against the token, and the
  fifth uses it up (`MAX_CODE_ATTEMPTS`); and against the address, across
  its tokens: past 10 in an hour (`MAX_CODE_FAILURES_PER_HOUR`), every
  code for it is refused until the hour is up, so asking for new codes
  doesn't buy more guesses. The link keeps working. Limits per IP stay
  the app's ([Rate-limiting](#rate-limiting-login-emails)).
- **Only an HMAC is stored** (`login_tokens.code_hash`, keyed by
  `AUTH_SECRET`): six digits are trivial to try offline against a plain
  hash.
- **The scaffold** turns the "check your email" page into the code form
  (`inputmode="numeric"`, `autocomplete="one-time-code"`, "Send a new
  code", "Wrong address?"), adds `POST /auth/code`, and starts the mail's
  subject with the code (`"482913 is your shop code"`), so a phone's
  notification shows it and Safari can offer it.

## Where a login returns

`request_login(redirect_to:)` (and `SendLoginLink.enqueue(email,
redirect_to)`) only takes a path `redirect_allowlist` allows. An entry is
a String, an exact path, or a Regexp, which must match the whole path
(Monk anchors it: `%r{/invite/\w+}` doesn't let `/invite/x/../admin`
through). The match is on the path only: a query string after an allowed
path is kept. Whatever the list says, a redirect starts with a single
`/`, never `//` or `/\`, which a browser reads as another host.

- **`Monk::Auth.allowed_redirect?(path)`** is the same check, for a route
  that enqueues `SendLoginLink`: in the job, an `InvalidRedirectError`
  would fail where nobody sees it.
- **`Monk::Auth.redirect_for(token)`** is where a token was going, even
  expired or used (nil for an unknown one), so a callback can send an
  expired link back to its page instead of a dead end:
  ```ruby
  get("/auth/callback/:token") do
    session = Monk::Auth.redeem(params[:token])
    redirect("#{Monk::Auth.redirect_for(params[:token]) || "/"}?expired=1") unless session
    # ...
  end
  ```

## Sessions renewed by use

A session lasts `session_ttl` from its last use, not from sign-in. When a
request's session has less than half of `session_ttl` left,
`current_subject` moves its `expires_at` to now + `session_ttl`, and
reissues both cookies: one `UPDATE` per session per half TTL, never per
request (a conditional one, so two requests arriving together write once).
A Bearer request renews the row too. The WebSocket's check never writes.

`session_max_age:` (nil by default: no cap) caps a session's whole life,
in seconds from its creation, however much it's used.

## The installed iPhone app's own session

Add to Home Screen copies Safari's cookies into the app once, so the
installed app starts signed in, but with the very same session: logging
out in either would log out both, and end the app's notifications. So on
its first launch the app asks for a session of its own:

- With auth configured, `<%= monk_head %>` adds `<meta
  name="monk-auth-own-url" content="/auth/own">`. In the installed app on
  iOS (`navigator.standalone`), Monk's `register.js` (with
  [pwa](pwa.md)) POSTs there once, and remembers it in `localStorage` once
  the server answered. Android's installed app shares Chrome's cookies,
  so it has nothing to split.
- The route, in the scaffold:
  ```ruby
  post("/auth/own") do
    require_csrf!
    own_session! || halt(401)
    json(ok: true)
  end
  ```
  `own_session!` splits the cookie's session (`Monk::Auth.split(token)`:
  a second session for the same subject, with the same `created_at` and
  `expires_at`) and sets the cookies for the new one. The old one is left
  to Safari.

## Sending the magic link from a job

With [background jobs](jobs.md), the login request doesn't have to wait
for the email to go out. Move the whole request into a job, not just the
send: the job creates the token and sends the link, so the raw token only
ever exists in memory and in the email. Monk ships this job as
`Monk::Auth::SendLoginLink`, defined once `monk/auth` and `monk/jobs` are
both loaded:

```ruby
post("/auth/request") do
  halt(429) unless Monk::Auth.allow_login_request?(params[:email]) # see "Rate-limiting login emails"
  Monk::Auth::SendLoginLink.enqueue(params[:email]) # or (email, redirect_to)
  json(sent: true)
end
```

It runs on the `mailers` queue with 3 attempts (a login email minutes late
is worse than none), never retries an `InvalidRedirectError`, and sends
`Monk::Auth.login_link(token)` and the code through your `deliver:`,
synchronously, in the job. Subclass it to change the queue or the retries.

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

## Rate-limiting login emails

Without a limit, anyone can make the app send login emails to any address,
as often as they like. `Monk::Auth.allow_login_request?(email)` allows one
per address per `login_request_interval:` (60 seconds by default, set in
`Monk::Auth.configure`), across every process:

```ruby
post("/auth/request") do
  email = params[:email].to_s.strip.downcase
  halt(422) if email.empty?
  halt(429) unless Monk::Auth.allow_login_request?(email)

  Monk::Auth::SendLoginLink.enqueue(email) # or request_login + deliver_link, without jobs
  json(sent: true)
end
```

- **It returns true and records the request**, or returns false and
  changes nothing, so asking again doesn't push the next allowed request
  further away. One statement on `login_requests`: two requests racing
  for one address can't both pass.
- **Check it in the route, before sending or enqueueing.** With jobs, the
  token only exists once `SendLoginLink` runs, so `login_tokens` can't
  tell that a link is already on its way.
- **The address is stripped and downcased for the limit**, so
  `Ann@x.test` and `ann@x.test` share one. What you pass on to
  `request_login` or `SendLoginLink` is up to you.
- **It limits each address, not each client.** One client asking for
  links to many different addresses passes. For that, add a limit of your
  own, per IP for instance: `Monk::Auth::RateLimiter.new(limit:, window:)`
  counts per process, in memory, which is approximate but enough to slow
  a flood; a Redis or Postgres counter is exact across processes.
- **In tests,** call `Monk::Auth.clear_login_requests!` in `teardown`,
  or a second test asking for a link for the same address gets a 429. It
  refuses to run unless `MONK_ENV=test`.

## Cleaning up expired rows

Expired sessions and login tokens stay in their tables until something
deletes them. `Monk::Auth.sweep!` deletes expired login tokens, sessions
expired for longer than `expired_retention:` (90 days by default), and
login requests older than `login_request_interval` (kept while their
wrong-code count still matters), at most 10,000 rows per statement so no
lock lasts long, and returns how many of each:
`{ login_tokens: 3, sessions: 41, login_requests: 12 }`.

- **With jobs**, `Monk::Auth::Sweep` runs it as a job, and the
  `config/recurring.rb` that `monk add jobs` writes schedules it every
  night at 03:17 UTC, when auth is installed:
  ```ruby
  Monk::Jobs.recurring "monk_auth_sweep", Monk::Auth::Sweep, cron: "17 3 * * *" if defined?(Monk::Auth::Sweep)
  ```
  Change the time there, or remove the line to clean up your own way.
  [`jobs.md`](jobs.md#recurring-jobs) covers how recurring jobs run.
- **Without jobs**, call `Monk::Auth.sweep!` on a schedule of your own:
  an external cron running a script that loads `config/load` and calls
  it, for instance.
- **Expired sessions are kept for `expired_retention`**, because
  [web push](push.md) keeps notifying an idle person through them until
  then. `expired_retention: 0` deletes them when they expire.

## Secure cookies

Both cookies carry the `Secure` flag by default, so browsers only send them
over HTTPS. Over plain `http://` (a dev server, a second device on the LAN)
Safari — Private Browsing especially — silently drops a `Secure` cookie, and
login appears to do nothing. Pass `secure: false` to
`Monk::Auth.configure` to omit the flag; `monk add auth`'s `config/auth.rb` does
this in development (`secure: !Monk.env.development?`) and keeps it on
everywhere else. Don't set it to `false` in production.
