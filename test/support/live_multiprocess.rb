require "rbconfig"
require "securerandom"
require "timeout"
require "monk/websocket"
require "monk/live"

# The publisher (this test process) and the WebSocket server (a child
# process) share nothing but the fanout's server: the shape of a real
# deployment, HTTP app in one process and the WS process in another.
#
# A module includes it and defines ws_process_script, ws_process_env and
# new_publishing_fanout(registry).
module LiveMultiprocess
  def start_ws_process
    reader, writer = IO.pipe
    @ws_pid = Process.spawn(ws_process_env, RbConfig.ruby, ws_process_script, out: writer)
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

  # A publisher in this process, the way an HTTP app would hold one: it
  # never calls #listen!, so it publishes without subscribing.
  def build_publisher
    @registry = Monk::WebSocket::Registry.new
    @fanout = new_publishing_fanout(@registry)
    @publisher = Monk::Live::Publisher.new(@fanout)
  end

  def unique_topic
    "t:#{SecureRandom.hex(4)}"
  end
end
