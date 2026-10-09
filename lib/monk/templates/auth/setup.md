## auth

Logging in by email link. `config/auth.rb` configures Monk::Auth,
`app/mailers/auth_mailer.rb` sends the link through mail, and a migration
creates the `login_tokens` and `sessions` tables: run `bin/setup_db` and
`DB_NAME={{app}}_test bin/setup_db` (postgres, above).

### Before production

`AUTH_SECRET` in `.env` and `.env.test` is a placeholder. Set a long random
one in production's environment, e.g. from
`ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`. `config/auth.rb`
reads it with `ENV.fetch`: unset, the app doesn't boot.

### Check it works

1. `bundle exec rake test` runs `test/auth_test.rb`: a link is sent (to
   `log/test.log`) and redeemed into a session.
2. By hand: the login routes are commented out in `app/routes/auth.rb`,
   block `auth-routes`. Uncomment them and restart `bin/server`. Then:
   - http://localhost:9292/me answers `401`: nobody is logged in.
   - http://localhost:9292/login: enter an email. In development the link
     is printed in `bin/server`'s console (and `log/development.log`), not
     sent. Open it: it logs you in and goes back to `/`.
   - http://localhost:9292/me now shows your email.
   - To log out, from the browser's console on any page of the app:

     ```js
     fetch("/auth/logout", { method: "POST", headers: {
       "x-csrf-token": document.cookie.match(/csrf_token=([^;]+)/)[1] } })
     ```

     and `/me` answers `401` again.
3. Before going live: keep the rate limit, and list in `config/auth.rb`
   (`redirect_allowlist`) the paths a login may send the user back to.
