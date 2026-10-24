require "socket"

# A just-enough HTTP server for the S3 backend's request-shape tests: runs
# on a thread in the main Ractor, records each request (verb, target,
# lowercased headers, body), and answers with the next canned response, or
# 200 with an empty body once they run out. Knobs:
#   responses: [[status, headers, body], ...] -- answered in order
#   silent:    accept the connection and never answer (read-timeout tests)
class FakeS3Server
  Request = Struct.new(:verb, :target, :headers, :body, keyword_init: true)

  attr_reader :port, :requests

  def initialize(responses: [], silent: false)
    @responses = responses.dup
    @silent = silent
    @requests = Thread::Queue.new
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { serve }
  end

  def endpoint
    "127.0.0.1:#{port}"
  end

  # The next recorded request, waiting for it if needed.
  def next_request
    @requests.pop(timeout: 5) or raise "no request reached the fake S3 server"
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def serve
    loop do
      client = @server.accept
      if @silent
        sleep
      else
        handle(client)
      end
    ensure
      client&.close unless @silent
    end
  end

  def handle(client)
    verb, target = client.gets.to_s.split
    headers = {}
    while (line = client.gets) && line != "\r\n"
      name, value = line.chomp.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
    @requests << Request.new(verb: verb, target: target, headers: headers, body: body)

    status, response_headers, response_body = @responses.shift || [200, {}, ""]
    client.write("HTTP/1.1 #{status} Fake\r\n")
    reply = { "content-length" => response_body.bytesize.to_s, "connection" => "close" }.merge(response_headers)
    reply.each { |name, value| client.write("#{name}: #{value}\r\n") }
    client.write("\r\n")
    client.write(response_body) unless verb == "HEAD"
  end
end
