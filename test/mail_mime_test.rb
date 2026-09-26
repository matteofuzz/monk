require_relative "test_helper"
require "monk/mail"

class MailMimeTest < Minitest::Test
  DATE = Time.utc(2026, 9, 26, 10, 30, 0)

  def build(**overrides)
    Monk::Mail::Message.new(
      from: "App <no-reply@app.test>", to: "ann@example.test", subject: "Your login link",
      text: "Log in: https://app.test/auth/callback/abc", **overrides,
    )
  end

  def mime(message, **)
    message.to_mime(date: DATE, message_id: "<fixed@app.test>", boundary: "BOUNDARY", **)
  end

  # Splits raw MIME into [headers Hash (unfolded), body String].
  def parse(raw)
    head, body = raw.split("\r\n\r\n", 2)
    headers = head.gsub(/\r\n[ \t]/, " ").split("\r\n").to_h { |line| line.split(": ", 2) }
    [headers, body]
  end

  def decode_b64(body) = body.unpack1("m").force_encoding(Encoding::UTF_8)

  # RFC 2047 decode, enough for what to_mime emits.
  def decode_words(value)
    value.gsub(/=\?UTF-8\?B\?([^?]+)\?=\s*/) { Regexp.last_match(1).unpack1("m").force_encoding(Encoding::UTF_8) }.strip
  end

  def test_text_only_message_is_a_single_base64_text_part
    headers, body = parse(mime(build))

    assert_equal "App <no-reply@app.test>", headers["From"]
    assert_equal "ann@example.test", headers["To"]
    assert_equal "Your login link", headers["Subject"]
    assert_equal "Sat, 26 Sep 2026 10:30:00 +0000", headers["Date"]
    assert_equal "<fixed@app.test>", headers["Message-ID"]
    assert_equal "1.0", headers["MIME-Version"]
    assert_equal "text/plain; charset=UTF-8", headers["Content-Type"]
    assert_equal "base64", headers["Content-Transfer-Encoding"]
    refute headers.key?("Reply-To")
    assert_equal "Log in: https://app.test/auth/callback/abc", decode_b64(body)
  end

  def test_html_only_message_is_a_single_base64_html_part
    headers, body = parse(mime(build(text: nil, html: "<p>Log in</p>")))

    assert_equal "text/html; charset=UTF-8", headers["Content-Type"]
    assert_equal "<p>Log in</p>", decode_b64(body)
  end

  def test_text_and_html_make_multipart_alternative_with_text_first
    raw = mime(build(text: "plain", html: "<p>rich</p>"))
    headers, body = parse(raw)

    assert_equal %(multipart/alternative; boundary="BOUNDARY"), headers["Content-Type"]
    refute headers.key?("Content-Transfer-Encoding")

    parts = body.split("--BOUNDARY")
    assert_equal "--\r\n", parts.last
    text_headers, text_body = parse(parts[1].delete_prefix("\r\n"))
    html_headers, html_body = parse(parts[2].delete_prefix("\r\n"))

    assert_equal "text/plain; charset=UTF-8", text_headers["Content-Type"]
    assert_equal "base64", text_headers["Content-Transfer-Encoding"]
    assert_equal "plain", decode_b64(text_body)
    assert_equal "text/html; charset=UTF-8", html_headers["Content-Type"]
    assert_equal "<p>rich</p>", decode_b64(html_body)
  end

  def test_reply_to_header_when_given
    headers, = parse(mime(build(reply_to: "Support <support@app.test>")))

    assert_equal "Support <support@app.test>", headers["Reply-To"]
  end

  def test_several_recipients_are_comma_separated
    headers, = parse(mime(build(to: ["ann@example.test", "Bob <bob@example.test>"])))

    assert_equal "ann@example.test, Bob <bob@example.test>", headers["To"]
  end

  def test_long_recipient_lists_are_folded
    to = (1..10).map { |i| "recipient-number-#{i}@example.test" }
    raw = mime(build(to: to))

    raw.split("\r\n").each { |line| assert_operator line.length, :<=, 78, line }
    headers, = parse(raw)
    assert_equal to, headers["To"].split(/,\s*/)
  end

  def test_non_ascii_subject_is_rfc2047_encoded_and_round_trips
    subject = "Il tuo link di accesso — città ✓"
    headers, = parse(mime(build(subject: subject)))

    assert_match(/\A=\?UTF-8\?B\?/, headers["Subject"])
    assert_equal subject, decode_words(headers["Subject"])
  end

  # RFC 2047: an encoded word is at most 75 characters, and a multibyte
  # character must not be split across two of them.
  def test_long_non_ascii_subject_splits_into_short_encoded_words_on_character_boundaries
    subject = "Ciao Niccolò, ecco il tuo link di accesso per l'applicazione — è valido per dieci minuti ✓"
    raw = mime(build(subject: subject))

    subject_lines = raw.split("\r\n").drop_while { |l| !l.start_with?("Subject:") }
                       .take_while { |l| l.start_with?("Subject:", " ") }
    assert_operator subject_lines.size, :>, 1
    raw.scan(/=\?UTF-8\?B\?[^?]+\?=/).each do |word|
      assert_operator word.length, :<=, 75
      assert word[/B\?(.+)\?=/, 1].unpack1("m").force_encoding(Encoding::UTF_8).valid_encoding?, word
    end
    headers, = parse(raw)
    assert_equal subject, decode_words(headers["Subject"])
  end

  def test_long_ascii_subject_is_folded_at_spaces_and_unfolds_back
    subject = "Your login link for the application is ready and it stays valid for exactly ten minutes from now"
    raw = mime(build(subject: subject))

    raw.split("\r\n").each { |line| assert_operator line.length, :<=, 78, line }
    headers, = parse(raw)
    assert_equal subject, headers["Subject"]
  end

  # "=?" in plain text would be read by a client as the start of an
  # encoded word, so such a subject is encoded instead of sent as-is.
  def test_ascii_subject_that_looks_like_an_encoded_word_is_encoded
    headers, = parse(mime(build(subject: "Code =?UTF-8?B?eA==?=")))

    assert_equal "Code =?UTF-8?B?eA==?=", decode_words(headers["Subject"])
  end

  def test_non_ascii_display_names_are_encoded_but_addresses_are_not
    headers, = parse(mime(build(from: "Città App <no-reply@app.test>", to: "Zoë <zoe@example.test>")))

    assert_match(/\A=\?UTF-8\?B\?[^?]+\?= <no-reply@app\.test>\z/, headers["From"])
    assert_equal "Città App", decode_words(headers["From"].delete_suffix(" <no-reply@app.test>"))
    assert_match(/ <zoe@example\.test>\z/, headers["To"])
  end

  # A comma in an unquoted display name would split one recipient into two.
  def test_ascii_display_names_with_specials_are_quoted
    headers, = parse(mime(build(to: %(Doe, John <john@example.test>), from: %(Say "hi" <a@app.test>))))

    assert_equal %("Doe, John" <john@example.test>), headers["To"]
    assert_equal %("Say \\"hi\\"" <a@app.test>), headers["From"]
  end

  def test_already_quoted_display_names_are_left_alone
    headers, = parse(mime(build(to: %("Doe, John" <john@example.test>))))

    assert_equal %("Doe, John" <john@example.test>), headers["To"]
  end

  def test_body_line_endings_are_normalized_to_crlf_before_encoding
    _, body = parse(mime(build(text: "one\ntwo\r\nthree")))

    assert_equal "one\r\ntwo\r\nthree", decode_b64(body)
  end

  def test_non_ascii_bodies_round_trip
    _, body = parse(mime(build(text: "Perché è così ✓")))

    assert_equal "Perché è così ✓", decode_b64(body)
  end

  def test_every_line_is_crlf_terminated_and_short
    raw = mime(build(text: "x" * 500, html: "<p>#{"é" * 300}</p>"))

    refute_match(/(?<!\r)\n/, raw)
    raw.split("\r\n").each { |line| assert_operator line.length, :<=, 78, line }
  end

  def test_defaults_generate_date_message_id_and_boundary
    raw = build(text: "a", html: "<p>a</p>").to_mime
    headers, = parse(raw)

    assert_match(/\A<[0-9a-f-]{36}@app\.test>\z/, headers["Message-ID"])
    assert_match(/\A\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} [+-]\d{4}\z/, headers["Date"])
    boundary = headers["Content-Type"][/boundary="([^"]+)"/, 1]
    refute_nil boundary
    assert_includes raw, "--#{boundary}--\r\n"
  end

  def test_message_ids_and_boundaries_differ_between_calls
    message = build(text: "a", html: "<p>a</p>")
    first = parse(message.to_mime).first
    second = parse(message.to_mime).first

    refute_equal first["Message-ID"], second["Message-ID"]
    refute_equal first["Content-Type"], second["Content-Type"]
  end

  def test_rejects_bodies_that_are_not_valid_utf8
    message = build(text: "caf\xE9".b)

    assert_raises(Monk::Mail::InvalidMessageError) { message.to_mime }
  end

  def test_to_mime_works_inside_a_non_main_ractor
    raw = Ractor.new do
      Monk::Mail::Message.new(
        from: "Città <a@app.test>", to: "b@example.test", subject: "Perché ✓", text: "t", html: "<p>h</p>",
      ).to_mime
    end.value

    headers, = parse(raw)
    assert_equal "Perché ✓", decode_words(headers["Subject"])
  end

  def test_envelope_addresses_are_the_bare_addresses
    message = build(from: "App <no-reply@app.test>", to: ["Ann <ann@example.test>", "bob@example.test"])

    assert_equal "no-reply@app.test", message.envelope_from
    assert_equal ["ann@example.test", "bob@example.test"], message.envelope_to
  end
end
