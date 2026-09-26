require_relative "test_helper"
require "monk/mail"

class MailLogTransportTest < Minitest::Test
  def build_message(**overrides)
    Monk::Mail::Message.new(
      from: "App <no-reply@app.test>", to: ["ann@example.test", "Bob <bob@example.test>"],
      subject: "Your login link", text: "Log in:\nhttps://app.test/auth/callback/abc", **overrides,
    )
  end

  # Runs the block under MONK_ENV=env with booted Settings and Monk::Log
  # (writing to a tmpdir); returns [stdout, log file contents]. Settings
  # has to be booted too, as in a real app: unbooted, Monk.env reads ENV,
  # which a worker Ractor can't.
  def deliver_under(env, &)
    with_log do |dir|
      with_settings do
        with_monk_env(env) do
          Monk::Settings.freeze_registry!
          Monk::Log.freeze_registry!
          out, = capture_io(&)
          [out, File.read(File.join(dir, "#{env}.log"))]
        end
      end
    end
  end

  def test_writes_one_summary_line_to_the_log
    _, log = deliver_under("production") { Monk::Mail::Transports::Log.new.deliver(build_message) }

    assert_equal 1, log.lines.size
    line = log.lines.first
    assert_includes line, "INFO [mail] "
    assert_includes line, %(from="App <no-reply@app.test>")
    assert_includes line, %(to="ann@example.test, Bob <bob@example.test>")
    assert_includes line, %(subject="Your login link")
    # Escaped, so a multi-line body can't break the one-line-per-entry log.
    assert_includes line, %(text="Log in:\\nhttps://app.test/auth/callback/abc")
  end

  def test_logs_the_html_body_only_by_size
    html = "<p>#{"x" * 100}</p>"
    _, log = deliver_under("production") { Monk::Mail::Transports::Log.new.deliver(build_message(html: html)) }

    assert_includes log, "html=#{html.bytesize} bytes"
    refute_includes log, "xxxx"
  end

  def test_includes_reply_to_when_given
    _, log = deliver_under("production") do
      Monk::Mail::Transports::Log.new.deliver(build_message(reply_to: "help@app.test"))
    end

    assert_includes log, %(reply_to="help@app.test")
  end

  def test_prints_nothing_to_stdout_outside_development
    out, = deliver_under("production") { Monk::Mail::Transports::Log.new.deliver(build_message) }

    assert_empty out
  end

  # Where a developer actually looks, and where the magic link gets clicked.
  def test_prints_the_readable_message_to_stdout_in_development
    out, log = deliver_under("development") do
      Monk::Mail::Transports::Log.new.deliver(build_message(html: "<p>Log in: <a href=\"https://app.test/x\">here</a></p>"))
    end

    assert_includes out, "From: App <no-reply@app.test>"
    assert_includes out, "To: ann@example.test, Bob <bob@example.test>"
    assert_includes out, "Subject: Your login link"
    assert_includes out, "Log in:\nhttps://app.test/auth/callback/abc"
    assert_includes out, %(<a href="https://app.test/x">here</a>)
    assert_equal 1, log.lines.size
  end

  def test_returns_the_message
    msg = build_message
    result = nil
    deliver_under("production") { result = Monk::Mail::Transports::Log.new.deliver(msg) }

    assert_same msg, result
  end

  def test_delivers_from_a_non_main_ractor
    msg = build_message
    _, log = deliver_under("production") do
      Ractor.new(msg) { |m| Monk::Mail::Transports::Log.new.deliver(m).subject }.value
    end

    assert_includes log, %(subject="Your login link")
  end
end
