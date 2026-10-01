# A stand-alone Monk::Live WebSocket process for the multi-process tests,
# the PgFanout counterpart to live_ws_process.rb: what bin/websocket_server
# would be in an app that uses Postgres instead of Redis for cross-process
# fan-out. Prints "PORT <n>" once it is listening AND its LISTEN is in
# effect -- Monk::Live.listen! returns only then -- so a test can publish
# from another process right after reading it.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "monk/live"
require "monk/websocket/pg_fanout"

# Module scope, so the blocks below are Ractor-shareable (self is a Module).
module LiveWsProcessPg
  ALLOW = proc { |_subject, _topic| true }
end

pg_opts = {
  host: ENV.fetch("MONK_TEST_PG_HOST"),
  port: ENV.fetch("MONK_TEST_PG_PORT").to_i,
  user: ENV.fetch("MONK_TEST_PG_USER"),
  password: ENV.fetch("MONK_TEST_PG_PASSWORD"),
  dbname: ENV.fetch("MONK_TEST_PG_DATABASE"),
}

registry = Monk::WebSocket::PgFanout.new(Monk::WebSocket::Registry.new, pg_opts: pg_opts)
Monk::Live.configure(registry: registry)
Monk::Live.authorize("t:*", anonymous: true, &LiveWsProcessPg::ALLOW)
Monk::Live.listen!
server = Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1")

puts "PORT #{server.port}"
$stdout.flush
server.run(&Monk::Live::HANDLER)
