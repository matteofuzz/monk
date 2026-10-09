## auth

**Where:** `config/auth.rb` (settings, `callback_path:`),
`app/routes/auth.rb` (the routes, commented: block `auth-routes`),
`app/mailers/auth_mailer.rb` (sends the link), `app/views/auth/login.erb`
(the login page), `app/views/mail/magic_link.erb` (the email's HTML).

**Main calls:** `Monk::Auth.request_login(email)` returns a token;
`Monk::Auth.login_link(token)` builds its link;
`Monk::Auth.deliver_link(email:, link:, token:)` sends it;
`Monk::Auth.redeem(token)` returns a session or nil. In routes:
`set_session_cookie(session)`, `current_subject` (nil when logged out),
`require_user!` (halts 401), `require_csrf!`, `log_out!`. With jobs:
`Monk::Auth::SendLoginLink.enqueue(email)`.

**Test:** `test/auth_test.rb` sends a link to `log/test.log` and redeems it.

**Pitfalls:**
- `/auth/request` needs a per-email rate limit before it goes live: without
  one, anyone can make the app send mail to any address.
- Never point `deliver:` at `Monk::Mail.deliver_later`: the link, token
  included, would sit in the job queue. Use `SendLoginLink` instead.
- Links come from `Monk::Settings[:public_url]`, never from request headers.
- A `redirect_to` must be listed in `redirect_allowlist`.
- Monk reads `params` from JSON bodies and query strings, not form bodies:
  pages post with `fetch`. A cookie-authenticated POST sends the
  `x-csrf-token` header (the `csrf_token` cookie's value).

**Examples:** `auth-routes` in `app/routes/auth.rb`.
