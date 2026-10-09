require_relative "test_helper"

# Redis is reachable at REDIS_URL (.env.test): SETUP.md, redis.
class RedisTest < Minitest::Test
  def test_redis_answers
    redis = Redis.new(url: Monk::Settings[:redis_url])

    assert_equal "PONG", redis.ping
  ensure
    redis&.close
  end
end
