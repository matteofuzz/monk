require "monk"
require "redis"

# Where this app's Redis is (monk add redis): for a cache, rate limits,
# locks, or as WebSocket's transport (config/websocket.rb). A local one by
# default in development and test; anywhere else REDIS_URL must be set.
Monk::Settings.configure do
  if Monk.env.development? || Monk.env.test?
    optional :redis_url, default: "redis://localhost:6379/0"
  else
    required :redis_url
  end
end
