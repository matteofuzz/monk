## redis

`REDIS_URL` in `.env` and `.env.test` points at a local Redis
(`redis://localhost:6379/0`). Outside development and test it has no
default: set it, or the app fails at boot.

### Start Redis

Check first whether one is already running (`docker ps`). Either point
`REDIS_URL` at it, or start one:

```bash
docker run --rm -d -p 6379:6379 --name {{app}}_redis redis:7
```

### Check it works

1. `bundle exec rake test` runs `test/redis_test.rb`, which pings it.
2. By hand, in `bin/console`: `Redis.new(url: Monk::Settings[:redis_url]).ping`
   answers `"PONG"`.
