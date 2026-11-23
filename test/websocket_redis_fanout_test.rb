require_relative "test_helper"
require_relative "support/fanout_contract"
require "monk/websocket/redis_fanout"

# RedisFanout: the fan-out over Redis pub/sub (docs/history/plan-websocket.md
# Phase 6). Everything it shares with PgFanout is in FanoutContract.
class WebSocketRedisFanoutTest < Minitest::Test
  include RedisTestHelpers
  include WebSocketTestHelpers
  include FanoutContract

  private

  def fanout_class = Monk::WebSocket::RedisFanout
  def new_fanout(registry = Monk::WebSocket::Registry.new) = fanout_class.new(registry, redis_url: redis_test_url)
  def unreachable_fanout = fanout_class.new(Monk::WebSocket::Registry.new, redis_url: "redis://127.0.0.1:1/0")
  def skip_unless_transport_available = skip_unless_redis_available
  def listening_fanout = new_fanout.listen!
  def current_publisher = Ractor.current[:monk_redis_fanout_publisher]
  def publisher_closed?(client) = !client.connected?

  # Clients with at least one pattern subscription (test/support/live_ws_process.rb).
  def subscriber_count
    redis_client { |redis| redis.call("CLIENT", "LIST").scan(/psub=(\d+)/).count { |(n)| n.to_i.positive? } }
  end

  # Every connection in pattern-subscribe mode, as a Redis restart would.
  def drop_listener
    redis_client { |redis| redis.call("CLIENT", "KILL", "TYPE", "pubsub") }
  end

  def publish_malformed(key)
    redis_client { |redis| redis.publish("#{fanout_class::CHANNEL_PREFIX}#{key}", "no origin separator") }
  end

  def redis_client
    redis = Redis.new(url: redis_test_url)
    yield redis
  ensure
    redis&.close
  end
end
