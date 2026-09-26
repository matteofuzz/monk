require_relative "test_helper"
require_relative "support/fake_smtp_server"
require "tempfile"
require "monk/mail"

class MailSMTPTransportTest < Minitest::Test
  SMTP = Monk::Mail::Transports::SMTP

  def setup
    SMTP.prepare!
  end

  def teardown
    @server&.stop
    @cert_file&.unlink
  end

  def start_server(**)
    @server = FakeSMTPServer.new(**)
  end

  def transport(host: "127.0.0.1", port: @server.port, user: nil, password: nil, tls: false, starttls: :never)
    SMTP.new(host: host, port: port, user: user, password: password, tls: tls, starttls: starttls)
  end

  def build_message(**overrides)
    Monk::Mail::Message.new(
      from: "App <no-reply@app.test>", to: ["Ann <ann@example.test>", "bob@example.test"],
      subject: "Your login link", text: "Log in: https://app.test/auth/callback/abc", **overrides,
    )
  end

  # Every delivery in this file runs inside a non-main Ractor, as it would
  # under kino -- that is the property this transport exists to have.
  def deliver_in_ractor(transport, message)
    Ractor.new(transport, message) do |t, m|
      t.deliver(m)
      :delivered
    rescue Monk::Mail::DeliveryError => e
      [:error, e.message, e.cause&.class&.name]
    end.value
  end

  # Trust the fake server's self-signed cert for the block, through the
  # env var OpenSSL's default store reads -- no test-only knob in the
  # transport itself, and verification stays on.
  def trusting_fake_cert(&)
    @cert_file = Tempfile.new(["fake-smtp", ".pem"])
    @cert_file.write(FakeSMTPServer.cert_and_key.first.to_pem)
    @cert_file.close
    with_env("SSL_CERT_FILE", @cert_file.path, &)
  end

  def test_delivers_envelope_and_mime_to_a_local_relay
    start_server

    assert_equal :delivered, deliver_in_ractor(transport, build_message)
    session = @server.last_session
    assert_equal "no-reply@app.test", session.mail_from
    assert_equal ["ann@example.test", "bob@example.test"], session.rcpt_to
    assert_includes session.data, "Subject: Your login link\r\n"
    assert_includes session.data, "To: Ann <ann@example.test>, bob@example.test\r\n"
    assert_nil session.auth
    refute session.tls
  end

  def test_helo_uses_the_senders_domain
    start_server
    deliver_in_ractor(transport, build_message)

    assert_equal "app.test", @server.last_session.helo
  end

  def test_starttls_and_auth_with_verified_certificate
    start_server(starttls: true)

    result = trusting_fake_cert do
      deliver_in_ractor(transport(host: "localhost", user: "me@app.test", password: "s3cret", starttls: :always),
        build_message,)
    end

    assert_equal :delivered, result
    session = @server.last_session
    assert session.tls
    assert_equal ["me@app.test", "s3cret"], session.auth
  end

  def test_implicit_tls
    start_server(implicit: true)

    result = trusting_fake_cert do
      deliver_in_ractor(transport(host: "localhost", user: "u", password: "p", tls: true), build_message)
    end

    assert_equal :delivered, result
    assert @server.last_session.tls
  end

  def test_starttls_auto_upgrades_when_offered_and_falls_back_when_not
    start_server(starttls: true)
    trusting_fake_cert { deliver_in_ractor(transport(host: "localhost", starttls: :auto), build_message) }
    assert @server.last_session.tls
    @server.stop

    start_server
    assert_equal :delivered, deliver_in_ractor(transport(starttls: :auto), build_message)
    refute @server.last_session.tls
  end

  # With credentials the URL default is :always -- a server (or a
  # middlebox) that doesn't offer STARTTLS must stop the send, never get
  # the password in clear.
  def test_starttls_always_refuses_a_server_without_it
    start_server

    status, message, = deliver_in_ractor(transport(user: "u", password: "p", starttls: :always), build_message)

    assert_equal :error, status
    assert_match(/STARTTLS/i, message)
  end

  def test_untrusted_certificate_fails_instead_of_sending
    start_server(starttls: true)

    status, _, cause = deliver_in_ractor(transport(host: "localhost", starttls: :always), build_message)

    assert_equal :error, status
    assert_equal "OpenSSL::SSL::SSLError", cause
  end

  def test_auth_rejection_raises_delivery_error_without_leaking_the_password
    start_server(reject: { auth: "535 5.7.8 Authentication failed" })

    status, message, = deliver_in_ractor(transport(user: "u", password: "hunter2", starttls: :auto), build_message)

    assert_equal :error, status
    assert_includes message, "535"
    refute_includes message, "hunter2"
  end

  def test_recipient_rejection_raises_delivery_error
    start_server(reject: { rcpt: "550 5.1.1 No such user" })

    status, message, = deliver_in_ractor(transport, build_message)

    assert_equal :error, status
    assert_includes message, "550"
  end

  def test_connection_refused_raises_delivery_error
    closed_port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }

    status, message, cause = deliver_in_ractor(transport(port: closed_port), build_message)

    assert_equal :error, status
    assert_includes message, "127.0.0.1:#{closed_port}"
    assert_equal "Errno::ECONNREFUSED", cause
  end

  def test_a_server_that_never_answers_times_out
    start_server(silent: true)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status, _, cause = deliver_in_ractor(transport.with(read_timeout: 0.3), build_message)

    assert_equal :error, status
    assert_equal "Net::ReadTimeout", cause
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
  end

  def test_timeouts_default_to_a_few_seconds
    t = transport(port: 25)

    assert_equal 5, t.open_timeout
    assert_equal 10, t.read_timeout
  end

  # Net::SMTP keeps its AUTH mechanisms in a class-level Hash that a worker
  # Ractor can't read until it's made shareable -- prepare! does that at
  # boot (Monk::Mail.freeze_registry!).
  def test_prepare_seals_net_smtps_auth_registry
    assert Ractor.shareable?(Net::SMTP::Authenticator.auth_classes)
  end

  def test_freeze_registry_prepares_an_smtp_transport
    Monk::Mail.configure(url: "smtp://localhost:25")
    Monk::Mail.freeze_registry!

    assert Ractor.shareable?(Net::SMTP::Authenticator.auth_classes)
  ensure
    Monk::Mail.reset!
  end

  def test_returns_the_message
    start_server
    message = build_message

    assert_same message, transport.deliver(message)
  end

  def test_dot_leading_body_lines_survive_transparency
    start_server
    deliver_in_ractor(transport, build_message(text: ".hidden\n..double"))

    body = @server.last_session.data.split("\r\n\r\n", 2).last
    assert_equal ".hidden\r\n..double", body.unpack1("m").force_encoding(Encoding::UTF_8)
  end
end
