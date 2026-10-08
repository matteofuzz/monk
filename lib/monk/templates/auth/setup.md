## auth

Logging in by email link. `config/auth.rb` configures Monk::Auth,
`app/mailers/auth_mailer.rb` sends the link through mail, and a migration
creates the `login_tokens` and `sessions` tables: run `bin/setup_db` and
`DB_NAME={{app}}_test bin/setup_db` (postgres, above).

### Turn on the login routes

They're commented out in `app/routes/auth.rb`, block `auth-routes`:
uncomment them, keep the rate limit, and list in `config/auth.rb`
(`redirect_allowlist`) the paths a login may send the user back to. Then
open http://localhost:9292/login: in development the link is printed to
the console, not sent.

### Before production

`AUTH_SECRET` in `.env` and `.env.test` is a placeholder. Set a long random
one in production's environment, e.g. from
`ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`. `config/auth.rb`
reads it with `ENV.fetch`: unset, the app doesn't boot.

### Check it works

`bundle exec rake test` runs `test/auth_test.rb`: a link is sent (to
`log/test.log`) and redeemed into a session.
