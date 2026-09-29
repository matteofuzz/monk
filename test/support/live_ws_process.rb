# A stand-alone Monk::Live WebSocket process for the multi-process tests:
# what bin/websocket_server would be in an app, with cross-process fan-out
# on. Prints "PORT <n>" once it is listening AND its Redis subscription is
# live -- Monk::Live.listen! returns only then -- so a test can publish
# from another process right after reading it.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "monk/live"
require "monk/websocket/redis_fanout"

# Module scope, so the blocks below are Ractor-shareable (self is a Module).
module LiveWsProcess
  ALLOW = proc { |_subject, _topic| true }
end

registry = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: ENV.fetch("REDIS_URL"))
Monk::Live.configure(registry: registry)
Monk::Live.authorize("t:*", anonymous: true, &LiveWsProcess::ALLOW)
Monk::Live.listen!
server = Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1")

puts "PORT #{server.port}"
$stdout.flush
server.run(&Monk::Live::HANDLER)
