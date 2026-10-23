require "socket"

# A TCP forwarder in front of the test Postgres, so a test can make the
# database go away and come back without stopping the real server:
# #stop closes the listener and every forwarded socket (the client sees
# its connection drop, then connection refused); #start listens again on
# the same port.
class TcpProxy
  attr_reader :port

  def initialize(target_host, target_port)
    @target_host = target_host
    @target_port = target_port
    @port = nil
    @sockets = []
    @lock = Mutex.new
  end

  def start
    @server = TCPServer.new("127.0.0.1", @port || 0)
    @port = @server.addr[1]
    @acceptor = Thread.new { accept_loop(@server) }
    self
  end

  def stop
    @server&.close
    @acceptor&.join
    @lock.synchronize do
      @sockets.each { |socket| socket.close unless socket.closed? }
      @sockets.clear
    end
    self
  end

  private

  def accept_loop(server)
    loop do
      client = server.accept
      upstream = TCPSocket.new(@target_host, @target_port)
      @lock.synchronize { @sockets.push(client, upstream) }
      pipe(client, upstream)
      pipe(upstream, client)
    end
  rescue IOError, Errno::EBADF, Errno::EINVAL
    # the listener was closed by #stop
  end

  def pipe(from, to)
    Thread.new do
      loop { to.write(from.readpartial(16_384)) }
    rescue IOError, SystemCallError
      from.close unless from.closed?
      to.close unless to.closed?
    end
  end
end
