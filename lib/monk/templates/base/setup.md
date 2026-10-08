# Setting up {{app}}

## First run

```bash
bundle install
bin/server              # the app on http://localhost:9292
```

## Tests

```bash
bundle exec rake test
```

`test/test_helper.rb` loads `.env.test` (if there is one), then the app the
way `config.ru` does, booted once as `APP`; `test/app_test.rb` makes a
request through it. Minitest, like Monk's own suite.

Each module added with `monk add` appends its own section below: the
services it needs, how to start them, and how to check it works.
