require "rbconfig"
require "securerandom"
require "timeout"
require "monk/websocket"
require "monk/websocket/redis_fanout"
require "monk/live"

# The publisher (this test process, holding a RedisFanout) and the WebSocket
# server (a child process, test/support/live_ws_process.rb) share nothing but
# Redis: the shape of a real deployment, HTTP app in one process and the WS
# process in another.
module LiveMultiprocessHelpers
  include RedisTestHelpers

  SCRIPT = File.expand_path("support/live_ws_process.rb", __dir__)

  def start_ws_process
    reader, writer = IO.pipe
    @ws_pid = Process.spawn({ "REDIS_URL" => redis_test_url }, RbConfig.ruby, SCRIPT, out: writer)
    writer.close
    line = Timeout.timeout(30) { reader.gets }
    raise "WS process did not start" unless line&.start_with?("PORT ")

    @ws_port = line.split.last.to_i
  ensure
    reader&.close
  end

  def stop_ws_process
    return unless @ws_pid

    Process.kill("TERM", @ws_pid)
    Process.wait(@ws_pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # A publisher in this process, the way an HTTP app would hold one.
  def build_publisher
    @registry = Monk::WebSocket::Registry.new
    @fanout = Monk::WebSocket::RedisFanout.new(@registry, redis_url: redis_test_url)
    @publisher = Monk::Live::Publisher.new(@fanout)
    sleep 0.3 # this process's own subscriber, as in websocket_redis_fanout_test.rb
  end

  def unique_topic
    "t:#{SecureRandom.hex(4)}"
  end
end
