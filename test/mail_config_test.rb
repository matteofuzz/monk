require_relative "test_helper"
require "monk/mail"

class MailConfigTest < Minitest::Test
  SMTP = Monk::Mail::Transports::SMTP
  LOG = Monk::Mail::Transports::Log

  def teardown
    Monk::Mail.reset!
  end

  def transport_for(url)
    Monk::Mail.configure(url: url)
    Monk::Mail.config[:transport]
  end

  def test_smtp_url_with_credentials_host_and_port
    transport = transport_for("smtp://user:secret@smtp.example.test:2525")

    assert_equal SMTP.new(host: "smtp.example.test", port: 2525, user: "user", password: "secret",
      tls: false, starttls: :always,), transport
  end

  def test_smtp_defaults_to_the_submission_port
    assert_equal 587, transport_for("smtp://user:secret@smtp.example.test").port
  end

  # Credentials over a connection that silently stays plaintext when a
  # middlebox strips STARTTLS would leak the password, so with a user the
  # default is to require it; a local relay without auth just uses it if
  # offered (Postfix on localhost usually isn't set up for TLS).
  def test_starttls_is_required_with_credentials_and_opportunistic_without
    assert_equal :always, transport_for("smtp://user:secret@smtp.example.test").starttls
    assert_equal :auto, transport_for("smtp://localhost:25").starttls
  end

  def test_local_relay_without_credentials
    transport = transport_for("smtp://localhost:25")

    assert_equal "localhost", transport.host
    assert_equal 25, transport.port
    assert_nil transport.user
    assert_nil transport.password
  end

  def test_starttls_can_be_overridden_in_the_query
    assert_equal :never, transport_for("smtp://localhost:25?starttls=never").starttls
    assert_equal :always, transport_for("smtp://localhost:25?starttls=always").starttls
    assert_equal :auto, transport_for("smtp://u:p@smtp.example.test?starttls=auto").starttls
  end

  def test_smtps_is_implicit_tls_on_its_own_port
    transport = transport_for("smtps://user:secret@smtp.example.test")

    assert transport.tls
    assert_equal :never, transport.starttls
    assert_equal 465, transport.port
  end

  # A password with @ or : in it has to be percent-encoded in the URL.
  def test_credentials_are_percent_decoded
    transport = transport_for("smtp://me%40app.test:p%40ss%3Aw%2Fd@smtp.example.test")

    assert_equal "me@app.test", transport.user
    assert_equal "p@ss:w/d", transport.password
  end

  def test_smtp_transport_never_shows_its_password
    transport = transport_for("smtp://user:hunter2@smtp.example.test")

    refute_includes transport.inspect, "hunter2"
    refute_includes transport.to_s, "hunter2"
    assert_includes transport.inspect, "user:***@smtp.example.test:587"
  end

  # net-smtp is installed for monk's own suite, so the missing-gem path is
  # driven by making `require` raise, on the transport class only -- the
  # receiver require_library! calls it on.
  def test_smtp_url_without_net_smtp_fails_at_configure_with_a_gemfile_hint
    SMTP.define_singleton_method(:require) { |_name| raise LoadError, "cannot load such file -- net/smtp" }

    error = assert_raises(Monk::Mail::MissingDependencyError) { transport_for("smtp://localhost:25") }

    assert_includes error.message, %(gem "net-smtp")
    assert_nil Monk::Mail.config
  ensure
    SMTP.singleton_class.remove_method(:require)
  end

  def test_log_url_never_needs_net_smtp
    SMTP.define_singleton_method(:require) { |_name| raise LoadError, "cannot load such file -- net/smtp" }

    assert_equal LOG.new, transport_for("log://")
  ensure
    SMTP.singleton_class.remove_method(:require)
  end

  def test_log_url
    assert_equal LOG.new, transport_for("log://")
  end

  def test_scheme_is_case_insensitive
    assert_instance_of SMTP, transport_for("SMTP://localhost:25")
  end

  def test_unknown_scheme_raises_naming_the_supported_ones
    error = assert_raises(Monk::Mail::InvalidMailUrlError) { transport_for("pigeon://coop") }

    assert_match(/pigeon/, error.message)
    assert_match(/smtp/, error.message)
    assert_match(/log/, error.message)
  end

  def test_malformed_urls_raise
    ["not a url", "smtp://", "smtp://:25", "smtp://localhost:25?starttls=maybe", "smtp://localhost:25?tls=1"]
      .each do |url|
        assert_raises(Monk::Mail::InvalidMailUrlError, url) { transport_for(url) }
      end
  end

  # The URL carries a password; an error message must never echo it.
  def test_errors_never_include_the_password
    error = assert_raises(Monk::Mail::InvalidMailUrlError) do
      transport_for("smtp://user:hunter2@localhost:25?starttls=maybe")
    end

    refute_includes error.message, "hunter2"
  end

  def test_no_url_means_log_in_development
    with_settings do
      with_monk_env("development") do
        assert_equal LOG.new, transport_for(nil)
        assert_equal LOG.new, transport_for("")
      end
    end
  end

  # Outside development, forgetting MAIL_URL must fail at boot rather than
  # when the first user never receives their login link.
  def test_no_url_raises_outside_development
    %w[test staging production].each do |env|
      with_settings do
        with_monk_env(env) do
          error = assert_raises(Monk::Mail::MissingMailUrlError, env) { transport_for(nil) }
          assert_match(/MAIL_URL/, error.message)
          assert_includes error.message, "MONK_ENV=#{env}"
        end
      end
    end
  end

  def test_from_is_kept_as_the_default_sender
    Monk::Mail.configure(url: "log://", from: "App <no-reply@app.test>")

    assert_equal "App <no-reply@app.test>", Monk::Mail.config[:from]
  end

  def test_from_is_optional
    Monk::Mail.configure(url: "log://")

    assert_nil Monk::Mail.config[:from]
  end

  def test_from_is_validated_like_a_header
    ["", "  ", "a@app.test\r\nBcc: eve@evil.test", 42].each do |from|
      assert_raises(Monk::Mail::InvalidMessageError, from.inspect) { Monk::Mail.configure(url: "log://", from: from) }
    end
  end

  def test_config_is_nil_until_configured
    assert_nil Monk::Mail.config
  end

  def test_registers_a_freeze_hook
    assert_includes Monk.freeze_hooks, Monk::Mail
  end

  def test_freeze_registry_without_configure_is_a_no_op
    Monk::Mail.freeze_registry!

    assert_nil Monk::Mail.config
  end

  # The regression the freeze hook exists for, same as Monk::Auth's: an
  # unfrozen config Hash can't be read from a worker Ractor at all.
  def test_frozen_config_is_readable_from_a_worker_ractor
    Monk::Mail.configure(url: "smtp://user:secret@smtp.example.test", from: +"a@app.test")
    Monk::Mail.freeze_registry!

    result = Ractor.new { [Monk::Mail.config[:transport].host, Monk::Mail.config[:from]] }.value

    assert_equal ["smtp.example.test", "a@app.test"], result
  end
end
