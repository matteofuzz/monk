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

`bundle exec rake test` runs `test/mail_test.rb`, which delivers a message
to `log/test.log`.
