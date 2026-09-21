# A stand-alone Monk::Live WebSocket process for the multi-process tests:
# what bin/websocket_server would be in an app, with cross-process fan-out
# on. Prints "PORT <n>" once it is listening AND its Redis subscription is
# live, so a test can publish from another process right after reading it.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "monk/live"
require "monk/websocket/redis_fanout"

# Module scope, so the blocks below are Ractor-shareable (self is a Module).
module LiveWsProcess
  ALLOW = proc { |_subject, _topic| true }

  def self.psub_clients(redis)
    redis.call("CLIENT", "LIST").scan(/psub=(\d+)/).count { |(count)| count.to_i.positive? }
  end
end

url = ENV.fetch("REDIS_URL")
probe = Redis.new(url: url)
before = LiveWsProcess.psub_clients(probe)

registry = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: url)
Monk::Live.configure(registry: registry)
Monk::Live.authorize("t:*", anonymous: true, &LiveWsProcess::ALLOW)
server = Monk::WebSocket::Server.new(port: 0, bind: "127.0.0.1")

sleep 0.05 until LiveWsProcess.psub_clients(probe) > before
puts "PORT #{server.port}"
$stdout.flush
server.run(&Monk::Live::HANDLER)
