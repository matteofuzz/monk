## auth

Logging in by email link, or by the 6-digit code sent with it (which works
where the link wouldn't: the installed app on an iPhone, a chat app's
built-in browser). `config/auth.rb` configures Monk::Auth,
`app/mailers/auth_mailer.rb` sends the link and code through mail, and
three migrations create the `login_tokens`, `sessions` and
`login_requests` tables: run `bin/setup_db` and
`DB_NAME={{app}}_test bin/setup_db` (postgres, above).

### Before production

`AUTH_SECRET` in `.env` and `.env.test` is a placeholder. Set a long random
one in production's environment, e.g. from
`ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`. `config/auth.rb`
reads it with `ENV.fetch`: unset, the app doesn't boot.

### Housekeeping

- **Rate limit.** The login route allows one email per address per
  minute (`login_request_interval:` in `config/auth.rb`), counted in
  `login_requests`, so across every `bin/server` process. A limit across
  addresses (per IP, say) is up to the app.
- **Wrong codes.** Five wrong codes use a login up; ten for one address
  in an hour lock its codes until the hour is up (the link still works).
- **Cleanup.** With jobs (`monk add jobs`), `bin/jobs` deletes expired
  login tokens, and sessions expired for longer than `expired_retention:`
  (90 days), every night (`monk_auth_sweep` in `config/recurring.rb`).
  Without jobs, run `Monk::Auth.sweep!` on a schedule of your own.

### Check it works

1. `bundle exec rake test` runs `test/auth_test.rb`: a link and code are
   sent (to `log/test.log`) and each redeems into a session.
2. By hand: the login routes are commented out in `app/routes/auth.rb`,
   block `auth-routes`. Uncomment them and restart `bin/server`. Then:
   - http://localhost:9292/me answers `401`: nobody is logged in.
   - http://localhost:9292/login: enter an email. In development the mail
     is printed, not sent: on `bin/server`'s console, or `bin/jobs`' when
     a job sends it (`Monk::Auth::SendLoginLink`), and in
     `log/development.log` either way. Type the code from its subject
     into the page, or open its link: either logs you in and goes back
     to `/`.
   - http://localhost:9292/me now shows your email.
   - To log out, from the browser's console on any page of the app:

     ```js
     fetch("/auth/logout", { method: "POST", headers: {
       "x-csrf-token": document.cookie.match(/csrf_token=([^;]+)/)[1] } })
     ```

     and `/me` answers `401` again.
3. Before going live: keep the rate limit (the `allow_login_request?`
   line in `app/routes/auth.rb`), and list in `config/auth.rb`
   (`redirect_allowlist`) the paths a login may send the user back to.
