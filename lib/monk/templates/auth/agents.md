## auth

**Where:** `config/auth.rb` (settings, `callback_path:`),
`app/routes/auth.rb` (the routes, commented: block `auth-routes`),
`app/mailers/auth_mailer.rb` (sends the link and the code),
`app/views/auth/login.erb` (the login page, then the code form),
`app/views/mail/magic_link.erb` (the email's HTML).

**Main calls:** `Monk::Auth.request_login(email)` returns
`{ token:, code: }`; `Monk::Auth.login_link(token)` builds the link;
`Monk::Auth.deliver_link(email:, link:, token:, code:)` sends both;
`Monk::Auth.redeem(token)` and `Monk::Auth.redeem_code(email, code)`
return a session or nil. In routes: `set_session_cookie(session)`,
`current_subject` (nil when logged out; renews a session in use),
`require_user!` (halts 401), `require_csrf!`, `log_out!`, `own_session!`
(the installed iPhone app's own session, `POST /auth/own`). With jobs:
`Monk::Auth::SendLoginLink.enqueue(email)`. Rate limit, in the login
route before sending: `halt(429) unless Monk::Auth.allow_login_request?(email)`
(one per address per `login_request_interval:`). `Monk::Auth.sweep!`
deletes expired rows; with jobs, `Monk::Auth::Sweep` runs it nightly
(`config/recurring.rb`); expired sessions are kept for
`expired_retention:` (90 days), since push still reaches them.

**Test:** `test/auth_test.rb` sends a link and code to `log/test.log` and
redeems each.
A test that asks for links calls `Monk::Auth.clear_login_requests!` in
`teardown`, or its next request for the same address gets a 429.

**Pitfalls:**
- Keep `allow_login_request?` in `/auth/request`: without a rate limit,
  anyone can make the app send mail to any address. It limits each
  address, not a client asking for many.
- Never point `deliver:` at `Monk::Mail.deliver_later`: the link, token
  included, would sit in the job queue. Use `SendLoginLink` instead.
- Links come from `Monk::Settings[:public_url]`, never from request headers.
- A `redirect_to` must be allowed by `redirect_allowlist` (exact paths, or
  Regexps matching the whole path). With jobs, check
  `Monk::Auth.allowed_redirect?(path)` before enqueueing `SendLoginLink`.
- `deliver:` is called with `email:, link:, token:, redirect_to:, code:`:
  take what you don't use with `**`.
- A cookie-authenticated POST calls `require_csrf!`, and sends the token:
  a form with `<%= csrf_field %>`, `fetch` with the `x-csrf-token` header
  (the `csrf_token` cookie's value).

**Examples:** `auth-routes` in `app/routes/auth.rb`.
