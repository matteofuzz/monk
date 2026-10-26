# Setting up {{app}}

## First run

```bash
bundle install
bin/server              # the app on http://localhost:9292
```

## Before production

Set `MONK_ENV=production` (or `staging`) wherever the app runs deployed.
Unset, it means `development`, and the app runs that way without an
error: mail printed instead of sent, magic links logged, demo routes on.
The `Dockerfile` already sets it; without the Dockerfile, set it in the
platform's env. `bin/server` warns when it listens beyond this machine
(`--bind 0.0.0.0`) with `MONK_ENV` unset. Platform examples:
`docs/guides/deploying.md` in the monk repo.

## Check it works

1. `bundle exec rake test` runs the tests.
2. By hand: with `bin/server` running, http://localhost:9292 shows
   "It works", and http://localhost:9292/hello answers `hello from monk`.

`test/test_helper.rb` loads `.env.test` (if there is one), then the app the
way `config.ru` does, booted once as `APP`; `test/app_test.rb` makes a
request through it. Minitest, like Monk's own suite.

Each module added with `monk add` appends its own section below: the
services it needs, how to start them, and how to check it works, with its
test and by hand.
