# The app's Redis connection setting: a cache, rate limits, locks, or
# WebSocket's transport.
Monk::Generator.define(:redis) do
  summary "Redis connection setting, for caching or as a WebSocket transport"
  installed_if "config/redis.rb"

  copy "config/redis.rb", role: :wiring
  copy "app/routes/redis.rb", role: :example
  copy "test/redis_test.rb", role: :test

  gem %(gem "redis", "~> 5.0")
  %i[development test example].each { |file| env file, { "REDIS_URL" => "redis://localhost:6379/0" } }

  service :redis, check: "redis-cli -p 6379 ping", setup: "SETUP.md#redis"
  next_step "start Redis (SETUP.md › redis)"
  setup_section "redis/setup.md"
  agents_section "redis/agents.md"
  set_before_production "REDIS_URL", "required outside development and test"
  example "redis-cache", todo: "uncomment and adapt; open a client per request, and close it"
end
