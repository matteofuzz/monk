require_relative "test_helper"
require_relative "live_multiprocess_helpers_pg"
require_relative "support/live_fanout_contract"

# LiveFanoutContract over a PgFanout, through Postgres only
# (docs/history/plan-live-pg-fanout.md).
class LivePgTest < Minitest::Test
  include WebSocketTestHelpers
  include LiveMultiprocessHelpersPg
  include LiveFanoutContract

  private

  def skip_unless_transport_available = skip_unless_postgres_available
  # Under the NOTIFY payload cap (docs/design/live-pg-fanout.md, "Where
  # this is worse than Redis"); the Redis test sends about 130 KB.
  def fragment_copies = 40
end
