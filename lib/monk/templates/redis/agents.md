## redis

**Where:** `config/redis.rb` declares the `redis_url` setting (from
`REDIS_URL`) and loads the `redis` gem.

**Main calls:** `Redis.new(url: settings[:redis_url])` in a route (or
`Monk::Settings[:redis_url]` elsewhere), then the redis gem's commands:
`get`, `set(key, value, ex: seconds)`, `incr`, `del`. Close it when done.

**Test:** `test/redis_test.rb` pings Redis at `.env.test`'s `REDIS_URL`.

**Pitfalls:**
- A Redis client isn't Ractor-shareable: never keep one in a constant or a
  module variable. Open it in the route (or job) that uses it.
- Monk has no Redis pool: each `Redis.new` is a connection. Close it.
- `REDIS_URL` is required outside development and test.

**Examples:** `redis-cache` in `app/routes/redis.rb`.
