# Routes that use the app's Redis (monk add redis).
#
# monk:example redis-cache -- a value computed once a minute, cached in Redis.
# # A Redis client can't be shared between Ractors, and routes run in them,
# # so each request opens its own; Monk has no Redis pool yet.
# class App
#   get("/cached/now") do
#     redis = Redis.new(url: settings[:redis_url])
#     now = redis.get("cached:now") || Time.now.to_i.to_s.tap { |value| redis.set("cached:now", value, ex: 60) }
#     json(now: now)
#   ensure
#     redis&.close
#   end
# end
# monk:end
