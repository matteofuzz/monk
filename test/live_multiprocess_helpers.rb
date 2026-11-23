require "monk/websocket/redis_fanout"
require_relative "support/live_multiprocess"

# LiveMultiprocess over Redis: the child is test/support/live_ws_process.rb.
module LiveMultiprocessHelpers
  include RedisTestHelpers
  include LiveMultiprocess

  def ws_process_script = File.expand_path("support/live_ws_process.rb", __dir__)
  def ws_process_env = { "REDIS_URL" => redis_test_url }
  def new_publishing_fanout(registry) = Monk::WebSocket::RedisFanout.new(registry, redis_url: redis_test_url)
end
