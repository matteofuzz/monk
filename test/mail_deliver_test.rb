require_relative "test_helper"
require_relative "support/fake_smtp_server"
require "monk/mail"

class MailDeliverTest < Minitest::Test
  def teardown
    Monk::Mail.reset!
    @server&.stop
  end

  def test_raises_when_not_configured
    error = assert_raises(Monk::Mail::NotConfiguredError) do
      Monk::Mail.deliver(to: "ann@example.test", subject: "s", text: "t")
    end

    assert_match(/Monk::Mail.configure/, error.message)
  end

  def test_uses_the_configured_default_from
    @server = FakeSMTPServer.new
    Monk::Mail.configure(url: "smtp://127.0.0.1:#{@server.port}?starttls=never", from: "App <no-reply@app.test>")

    message = Monk::Mail.deliver(to: "ann@example.test", subject: "Hi", text: "t")

    assert_equal "App <no-reply@app.test>", message.from
    assert_equal "no-reply@app.test", @server.last_session.mail_from
  end

  def test_from_can_be_overridden_per_send
    @server = FakeSMTPServer.new
    Monk::Mail.configure(url: "smtp://127.0.0.1:#{@server.port}?starttls=never", from: "App <no-reply@app.test>")

    Monk::Mail.deliver(from: "Support <help@app.test>", to: "ann@example.test", subject: "Hi", text: "t")

    assert_equal "help@app.test", @server.last_session.mail_from
  end

  def test_raises_when_there_is_no_from_anywhere
    Monk::Mail.configure(url: "log://")

    error = assert_raises(Monk::Mail::InvalidMessageError) do
      Monk::Mail.deliver(to: "ann@example.test", subject: "s", text: "t")
    end
    assert_match(/from:/, error.message)
  end

  def test_passes_every_field_through
    @server = FakeSMTPServer.new
    Monk::Mail.configure(url: "smtp://127.0.0.1:#{@server.port}?starttls=never", from: "a@app.test")

    message = Monk::Mail.deliver(
      to: ["ann@example.test", "bob@example.test"], subject: "Hi", text: "plain", html: "<p>rich</p>",
      reply_to: "help@app.test",
    )

    assert_equal ["ann@example.test", "bob@example.test"], message.to
    assert_equal "<p>rich</p>", message.html
    data = @server.last_session.data
    assert_includes data, "Reply-To: help@app.test\r\n"
    assert_includes data, "multipart/alternative"
  end

  def test_invalid_input_raises_before_anything_is_sent
    @server = FakeSMTPServer.new
    Monk::Mail.configure(url: "smtp://127.0.0.1:#{@server.port}?starttls=never", from: "a@app.test")

    assert_raises(Monk::Mail::InvalidMessageError) do
      Monk::Mail.deliver(to: "ann@example.test\r\nBcc: eve@evil.test", subject: "s", text: "t")
    end
    assert_raises(ThreadError) { @server.sessions.pop(true) }
  end

  def test_delivery_errors_propagate
    closed_port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    Monk::Mail.configure(url: "smtp://127.0.0.1:#{closed_port}?starttls=never", from: "a@app.test")

    assert_raises(Monk::Mail::DeliveryError) { Monk::Mail.deliver(to: "ann@example.test", subject: "s", text: "t") }
  end

  # The whole point, end to end: a booted app whose route sends mail,
  # called from a worker Ractor as kino would, over real SMTP.
  def test_a_route_in_a_booted_app_sends_mail_from_a_worker_ractor
    @server = FakeSMTPServer.new
    with_log do
      with_settings do
        Monk::Mail.configure(url: "smtp://127.0.0.1:#{@server.port}?starttls=never", from: "App <no-reply@app.test>")
        app = Class.new(Monk::Base) do
          post("/login/:who") do
            Monk::Mail.deliver(to: "#{params[:who]}@example.test", subject: "Your login link", text: "Log in: ...")
            "sent"
          end
        end
        Monk.boot(app)

        result = Ractor.new(app) do |a|
          code, _headers, chunks = a.call({ "REQUEST_METHOD" => "POST", "PATH_INFO" => "/login/ann" })
          [code, chunks.join]
        end.value

        assert_equal [200, "sent"], result
      end
    end

    session = @server.last_session
    assert_equal ["ann@example.test"], session.rcpt_to
    assert_includes session.data, "Subject: Your login link\r\n"
  end
end
