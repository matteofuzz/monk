## mail

**Where:** `config/mail.rb` (from `MAIL_URL`, `MAIL_FROM`), mailers in
`app/mailers/` (module methods), HTML parts in `app/views/mail/`.

**Main calls:** `Monk::Mail.deliver(to:, subject:, text:, html:)`;
`Monk::Mail.render("mail/<template>", **locals)` for the HTML part (the
template reads `locals[:name]`). With jobs:
`Monk::Mail.deliver_later(...)`, the same arguments.

**Test:** `test/mail_test.rb` delivers to `log/test.log` (`MAIL_URL=log://`
in `.env.test`); assert on that file's lines.

**Pitfalls:**
- `deliver` waits for the mail server. In a request that matters: use
  `deliver_later` once jobs are installed.
- Render the HTML before `deliver_later`: the job only sends.
- `MAIL_URL` is required outside development; `MAIL_FROM` must be on a
  verified domain, or mail lands in spam.

**Examples:** `mail-welcome` in `app/mailers/app_mailer.rb` and
`app/routes/mail.rb`.
