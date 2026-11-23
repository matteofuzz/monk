require "monk/websocket/pg_fanout"
require_relative "support/live_multiprocess"

# LiveMultiprocess over Postgres only, for an app that doesn't run Redis:
# the child is test/support/live_ws_process_pg.rb.
module LiveMultiprocessHelpersPg
  include PersistenceTestHelpers
  include LiveMultiprocess

  def ws_process_script = File.expand_path("support/live_ws_process_pg.rb", __dir__)
  def new_publishing_fanout(registry) = Monk::WebSocket::PgFanout.new(registry, pg_opts: pg_test_opts)

  def ws_process_env
    opts = pg_test_opts
    {
      "MONK_TEST_PG_HOST" => opts[:host],
      "MONK_TEST_PG_PORT" => opts[:port].to_s,
      "MONK_TEST_PG_USER" => opts[:user],
      "MONK_TEST_PG_PASSWORD" => opts[:password],
      "MONK_TEST_PG_DATABASE" => opts[:dbname],
      "MONK_TEST_PG_APPLICATION_NAME" => ws_application_name,
    }
  end

  # The child's Postgres application_name, unique per test.
  def ws_application_name
    @ws_application_name ||= "monk_live_ws_#{SecureRandom.hex(4)}"
  end

  # The child's LISTEN backend, once it is listening.
  def ws_listen_pid
    conn = PG.connect(**pg_test_opts)
    conn.exec_params(
      "SELECT pid FROM pg_stat_activity WHERE application_name = $1 AND query = $2",
      [ws_application_name, "LISTEN #{Monk::WebSocket::PgFanout::CHANNEL}"],
    ).column_values(0).first
  ensure
    conn&.close
  end
end
