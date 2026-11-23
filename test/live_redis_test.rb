require_relative "test_helper"
require_relative "live_multiprocess_helpers"
require_relative "support/live_fanout_contract"

# LiveFanoutContract over a RedisFanout.
class LiveRedisTest < Minitest::Test
  include WebSocketTestHelpers
  include LiveMultiprocessHelpers
  include LiveFanoutContract

  private

  def skip_unless_transport_available = skip_unless_redis_available
  # About 130 KB.
  def fragment_copies = 2_500
end
