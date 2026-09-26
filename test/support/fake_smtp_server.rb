require "socket"
require "openssl"

# A just-enough SMTP server for the smtp:// transport tests: runs on a
# thread in the main Ractor, speaks EHLO / STARTTLS / AUTH PLAIN / MAIL /
# RCPT / DATA / QUIT, and records what the client sent. Knobs:
#   starttls:  advertise STARTTLS (needs cert:)
#   implicit:  TLS from the first byte, smtps-style (needs cert:)
#   reject:    { auth: "535 ...", rcpt: "550 ...", mail: "..." } -- answer that command with an error
#   silent:    accept the connection and never greet (read-timeout tests)
class FakeSMTPServer
  Session = Struct.new(:helo, :tls, :auth, :mail_from, :rcpt_to, :data, keyword_init: true)

  # A self-signed cert for localhost/127.0.0.1, generated once per process.
  def self.cert_and_key
    @cert_and_key ||= begin
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.public_key = key.public_key
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=localhost")
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      factory = OpenSSL::X509::ExtensionFactory.new
      factory.subject_certificate = factory.issuer_certificate = cert
      cert.add_extension(factory.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1"))
      cert.add_extension(factory.create_extension("basicConstraints", "CA:TRUE", true))
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      [cert, key]
    end
  end

  attr_reader :port, :sessions

  def initialize(starttls: false, implicit: false, reject: {}, silent: false)
    @starttls = starttls
    @implicit = implicit
    @reject = reject
    @silent = silent
    @sessions = Queue.new
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { accept_loop }
  end

  def stop
    @thread.kill
    @server.close
  end

  # The next finished session, waiting briefly for the client's QUIT.
  def last_session
    @sessions.pop(timeout: 2) or raise "no SMTP session recorded"
  end

  private

  def accept_loop
    loop do
      client = @server.accept
      Thread.new(client) do |io|
        serve(io)
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      ensure
        io.close unless io.closed?
      end
    end
  end

  def tls_context
    cert, key = self.class.cert_and_key
    OpenSSL::SSL::SSLContext.new.tap do |ctx|
      ctx.cert = cert
      ctx.key = key
    end
  end

  def upgrade(io)
    OpenSSL::SSL::SSLSocket.new(io, tls_context).tap do |ssl|
      ssl.sync_close = true
      ssl.accept
    end
  end

  def serve(io)
    return sleep if @silent

    session = Session.new(tls: @implicit, rcpt_to: [])
    io = upgrade(io) if @implicit
    io.write "220 fake.test ESMTP\r\n"
    while (line = io.gets)
      verb = line[/\A\S+/].to_s.upcase
      case verb
      when "EHLO", "HELO"
        session.helo = line.split(" ", 2).last.strip
        extensions = ["AUTH PLAIN LOGIN"]
        extensions.unshift("STARTTLS") if @starttls && !session.tls
        lines = ["fake.test", *extensions]
        io.write(lines.each_with_index.map { |l, i| "250#{i == lines.size - 1 ? " " : "-"}#{l}\r\n" }.join)
      when "STARTTLS"
        io.write "220 go ahead\r\n"
        io = upgrade(io)
        session.tls = true
      when "AUTH"
        next io.write("#{@reject[:auth]}\r\n") if @reject[:auth]

        _, user, pass = line.split[2].unpack1("m").split("\0")
        session.auth = [user, pass]
        io.write "235 ok\r\n"
      when "MAIL"
        next io.write("#{@reject[:mail]}\r\n") if @reject[:mail]

        session.mail_from = line[/<([^>]*)>/, 1]
        io.write "250 ok\r\n"
      when "RCPT"
        next io.write("#{@reject[:rcpt]}\r\n") if @reject[:rcpt]

        session.rcpt_to << line[/<([^>]*)>/, 1]
        io.write "250 ok\r\n"
      when "DATA"
        io.write "354 go ahead\r\n"
        data = +""
        while (body_line = io.gets) && body_line != ".\r\n"
          data << body_line.sub(/\A\./, "")
        end
        session.data = data
        io.write "250 queued\r\n"
      when "QUIT"
        io.write "221 bye\r\n"
        @sessions << session
        break
      else
        io.write "250 ok\r\n"
      end
    end
  end
end
