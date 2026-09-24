# A stand-alone Monk::Live WebSocket process for the multi-process tests,
# the PgFanout counterpart to live_ws_process.rb: what bin/websocket_server
# would be in an app that uses Postgres instead of Redis for cross-process
# fan-out. Prints "PORT <n>" once it is listening AND its LISTEN is
# actually registered on the server, so a test can publish from another
# process right after reading it.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "monk/live"
require "monk/websocket/pg_fanout"

# Module scope, so the blocks below are Ractor-shareable (self is a Module).
module LiveWsProcessPg
  ALLOW = proc { |_subject, _topic| true }

  # Postgres has no per-channel client count the way Redis's CLIENT LIST
  # gives psub= for free -- pg_stat_activity keeps the *last* query text
  # for an idle backend (state = 'idle', query = its last statement), so a
  # backend that issued LISTEN monk_live and is now blocked in
  # wait_for_notify shows up here with that exact query text.
  def self.listener_count(conn)
    conn.exec_params(
      "SELECT count(*) FROM pg_stat_activity WHERE query = $1 AND datname = current_database()",
      ["LISTEN #{Monk::WebSocket::PgFanout::CHANNEL}"],
    ).getvalue(0, 0).to_i
  end
end

pg_opts = {
  host: ENV.fetch("MONK_TEST_PG_HOST"),
  port: ENV.fetch("MONK_TEST_PG_PORT").to_i,
  user: ENV.fetch("MONK_TEST_PG_USER"),
  password: ENV.fetch("MONK_TEST_PG_PASSWORD"),
  dbname: ENV.fetch("MONK_TEST_PG_DATABASE"),
}

probe = PG.connect(**pg_opts)
before = LiveWsProcessPg.listener_count(probe)

registry = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_opts)
Monk::Live.configure(registry: registry)
Monk::Live.authorize("t:*", anonymous: true, &LiveWsProcessPg::ALLOW)
server = Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1")

sleep 0.05 until LiveWsProcessPg.listener_count(probe) > before
puts "PORT #{server.port}"
$stdout.flush
server.run(&Monk::Live::HANDLER)
