require_relative "test_helper"
require "json"
require "monk/live"

class LiveEnvelopeTest < Minitest::Test
  Envelope = Monk::Live::Envelope

  def test_a_patch_encodes_to_the_wire_shape
    json = Envelope.encode(Envelope.patch(target: "#contact-1", mode: :morph, html: "<li>x</li>"))

    assert_equal(
      { "op" => "patch", "target" => "#contact-1", "mode" => "morph", "html" => "<li>x</li>" },
      JSON.parse(json),
    )
  end

  def test_the_encoded_envelope_is_a_frozen_shareable_string
    json = Envelope.encode(Envelope.patch(target: "#a", mode: :morph, html: "x"))

    assert_instance_of String, json
    assert_predicate json, :frozen?
    assert Ractor.shareable?(json)
  end

  def test_remove_carries_no_html
    envelope = Envelope.patch(target: "#a", mode: :remove)

    assert_equal({ "op" => "patch", "target" => "#a", "mode" => "remove" }, JSON.parse(Envelope.encode(envelope)))
  end

  def test_every_mode_except_remove_requires_html
    (Envelope::MODES - [:remove]).each do |mode|
      assert_raises(ArgumentError) { Envelope.patch(target: "#a", mode: mode) }
    end
  end

  def test_remove_rejects_html
    assert_raises(ArgumentError) { Envelope.patch(target: "#a", mode: :remove, html: "x") }
  end

  def test_an_unknown_mode_is_rejected
    error = assert_raises(ArgumentError) { Envelope.patch(target: "#a", mode: :explode, html: "x") }

    assert_includes error.message, "explode"
  end

  def test_a_blank_or_non_string_target_is_rejected
    ["", "  ", nil, :sym].each do |target|
      assert_raises(ArgumentError) { Envelope.patch(target: target, mode: :remove) }
    end
  end

  def test_a_batch_wraps_ops_in_order
    ops = [Envelope.patch(target: "#a", mode: :morph, html: "1"), Envelope.patch(target: "#b", mode: :remove)]

    parsed = JSON.parse(Envelope.encode(Envelope.batch(ops)))

    assert_equal "batch", parsed["op"]
    assert_equal(%w[#a #b], parsed["ops"].map { |op| op["target"] })
  end

  def test_an_empty_batch_is_rejected
    assert_raises(ArgumentError) { Envelope.batch([]) }
  end

  def test_html_with_quotes_and_unicode_round_trips
    html = %(<p title="a&b">caffè "x" ☃ </p>)

    assert_equal html, JSON.parse(Envelope.encode(Envelope.patch(target: "#a", mode: :replace, html: html)))["html"]
  end

  def test_encodes_from_a_non_main_ractor
    json = Ractor.new { Monk::Live::Envelope.encode(Monk::Live::Envelope.patch(target: "#a", mode: :remove)) }.value

    assert_equal "remove", JSON.parse(json)["mode"]
  end
end
