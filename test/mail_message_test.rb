require_relative "test_helper"
require "monk/mail"

class MailMessageTest < Minitest::Test
  def build(**overrides)
    Monk::Mail::Message.new(
      from: "App <no-reply@app.test>", to: "ann@example.test", subject: "Your login link",
      text: "Log in: https://app.test/auth/callback/abc", **overrides,
    )
  end

  def test_builds_with_text_only
    message = build

    assert_equal "App <no-reply@app.test>", message.from
    assert_equal ["ann@example.test"], message.to
    assert_equal "Your login link", message.subject
    assert_nil message.html
    assert_nil message.reply_to
  end

  def test_builds_with_html_only
    message = build(text: nil, html: "<p>Log in</p>")

    assert_nil message.text
    assert_equal "<p>Log in</p>", message.html
  end

  def test_to_accepts_an_array_of_recipients
    message = build(to: ["ann@example.test", "Bob <bob@example.test>"])

    assert_equal ["ann@example.test", "Bob <bob@example.test>"], message.to
  end

  def test_keeps_reply_to
    assert_equal "support@app.test", build(reply_to: "support@app.test").reply_to
  end

  # The point of a Data value here: built inside one worker Ractor, it can
  # be handed to a transport (or another Ractor) without a copy.
  def test_is_deeply_frozen_and_shareable_even_from_mutable_input
    from = +"App <no-reply@app.test>"
    to = [+"ann@example.test"]
    message = build(from: from, to: to, text: +"hi", html: +"<p>hi</p>")

    assert Ractor.shareable?(message)
    from << "x"
    to << "eve@example.test"

    assert_equal "App <no-reply@app.test>", message.from
    assert_equal ["ann@example.test"], message.to
  end

  def test_can_be_built_inside_a_non_main_ractor
    result = Ractor.new do
      Monk::Mail::Message.new(from: "a@app.test", to: "b@example.test", subject: "s", text: "t").to
    end.value

    assert_equal ["b@example.test"], result
  end

  def test_rejects_missing_or_blank_required_fields
    [
      { from: nil }, { from: "" }, { from: "   " },
      { to: nil }, { to: "" }, { to: [] }, { to: ["ann@example.test", ""] },
      { subject: nil }, { subject: "" },
    ].each do |overrides|
      assert_raises(Monk::Mail::InvalidMessageError, overrides.inspect) { build(**overrides) }
    end
  end

  def test_rejects_non_string_fields
    [{ from: :app }, { to: 42 }, { to: [:ann] }, { subject: 1 }, { text: 1 }, { html: [] }, { reply_to: 1 }]
      .each do |overrides|
        assert_raises(Monk::Mail::InvalidMessageError, overrides.inspect) { build(**overrides) }
      end
  end

  def test_requires_a_text_or_html_body
    error = assert_raises(Monk::Mail::InvalidMessageError) { build(text: nil, html: nil) }

    assert_match(/text: or html:/, error.message)
  end

  # A CR or LF in a header value would let whoever controls it (a user
  # typing their email into a login form) add headers -- a Bcc: to anyone.
  def test_rejects_line_breaks_in_header_fields
    [
      { from: "a@app.test\r\nBcc: eve@evil.test" },
      { to: "ann@example.test\nBcc: eve@evil.test" },
      { to: ["ok@example.test", "ann@example.test\rBcc: eve@evil.test"] },
      { subject: "hi\r\nBcc: eve@evil.test" },
      { reply_to: "r@app.test\nBcc: eve@evil.test" },
    ].each do |overrides|
      error = assert_raises(Monk::Mail::InvalidMessageError, overrides.inspect) { build(**overrides) }
      assert_match(/line break/, error.message)
    end
  end

  def test_bodies_may_contain_line_breaks
    message = build(text: "line 1\nline 2", html: "<p>1</p>\r\n<p>2</p>")

    assert_equal "line 1\nline 2", message.text
  end

  def test_invalid_message_error_is_an_argument_error
    assert_operator Monk::Mail::InvalidMessageError, :<, ArgumentError
  end
end
