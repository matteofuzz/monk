## mail

In development `MAIL_URL` is unset, so every message is printed to the
console (and `log/development.log`) instead of sent. Tests use
`MAIL_URL=log://` (`.env.test`): messages go to `log/test.log`.

### Before production

Set `MAIL_URL` to your provider's SMTP relay, e.g.
`smtp://user:password@smtp.provider.com:587`, and `MAIL_FROM` to a sender on
a domain you've verified with that provider (SPF, DKIM). An unset `MAIL_URL`
fails the boot outside development. Provider examples:
`docs/guides/mail.md` in the monk repo.

### Check it works

1. `bundle exec rake test` runs `test/mail_test.rb`, which delivers a
   message to `log/test.log`.
2. By hand, in `bin/console`:
   `Monk::Mail.deliver(to: "you@example.com", subject: "Hi", text: "Hello")`.
   In development the message is printed right there (and in
   `log/development.log`), not sent.
3. The example: uncomment the `mail-welcome` blocks in
   `app/mailers/app_mailer.rb` and `app/routes/mail.rb`, restart
   `bin/server`, and send one:

   ```bash
   curl -X POST http://localhost:9292/welcome -H "content-type: application/json" \
     -d '{"email": "ann@example.com", "name": "Ann"}'
   ```

   The welcome email is printed in `bin/server`'s console.
