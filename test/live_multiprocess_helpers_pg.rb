require "rbconfig"
require "securerandom"
require "timeout"
require "monk/websocket"
require "monk/websocket/pg_fanout"
require "monk/live"

# The PgFanout counterpart to live_multiprocess_helpers.rb: the publisher
# (this test process, holding a PgFanout) and the WebSocket server (a
# child process, test/support/live_ws_process_pg.rb) share nothing but
# Postgres -- the shape of a real deployment, HTTP app in one process and
# the WS process in another, for an app that already runs Postgres and
# doesn't need Redis.
module LiveMultiprocessHelpersPg
  include PersistenceTestHelpers

  SCRIPT = File.expand_path("support/live_ws_process_pg.rb", __dir__)

  def start_ws_process
    reader, writer = IO.pipe
    opts = pg_test_opts
    env = {
      "MONK_TEST_PG_HOST" => opts[:host],
      "MONK_TEST_PG_PORT" => opts[:port].to_s,
      "MONK_TEST_PG_USER" => opts[:user],
      "MONK_TEST_PG_PASSWORD" => opts[:password],
      "MONK_TEST_PG_DATABASE" => opts[:dbname],
      "MONK_TEST_PG_APPLICATION_NAME" => ws_application_name,
    }
    @ws_pid = Process.spawn(env, RbConfig.ruby, SCRIPT, out: writer)
    writer.close
    line = Timeout.timeout(30) { reader.gets }
    raise "WS process did not start" unless line&.start_with?("PORT ")

    @ws_port = line.split.last.to_i
  ensure
    reader&.close
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

  def stop_ws_process
    return unless @ws_pid

    Process.kill("TERM", @ws_pid)
    Process.wait(@ws_pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # A publisher in this process, the way an HTTP app would hold one: it
  # never calls #listen!, so it publishes without subscribing.
  def build_publisher
    @registry = Monk::WebSocket::Registry.new
    @fanout = Monk::WebSocket::PgFanout.new(@registry, pg_opts: pg_test_opts)
    @publisher = Monk::Live::Publisher.new(@fanout)
  end

  def unique_topic
    "t:#{SecureRandom.hex(4)}"
  end
end
