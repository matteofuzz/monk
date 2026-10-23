require_relative "test_helper"
require "monk/storage"

class StorageSniffTest < Minitest::Test
  SNIFF = Monk::Storage::Sniff

  # An Ogg stream's first page: "OggS", version 0, the beginning-of-stream
  # flag, granule position, serial, sequence number, CRC, then the segment
  # table (here one segment of 19 bytes) and the packet itself (RFC 7845).
  def self.ogg_page(packet, segments: [packet.bytesize])
    ["OggS", 0, 2, 0, 0x1234, 0, 0, segments.size, *segments].pack("a4CCQ<L<L<L<CC*") + packet
  end

  OPUS_HEAD = "OpusHead\x01\x02\x38\x01\x80\xBB\x00\x00\x00\x00\x00".b

  # The first bytes of a real file of each type.
  FIXTURES = {
    "image/png" => "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\b\x06\x00\x00\x00".b,
    "image/jpeg" => "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00".b,
    "image/gif" => "GIF89a\x01\x00\x01\x00\x80\x00\x00\xFF\xFF\xFF\x00\x00\x00!".b,
    "image/webp" => "RIFF\x24\x00\x00\x00WEBPVP8 \x18\x00\x00\x00".b,
    "audio/ogg" => ogg_page(OPUS_HEAD),
    "application/pdf" => "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n1 0 obj\n<< /Type /Catalog".b,
  }.freeze

  def test_each_type_from_its_first_bytes
    FIXTURES.each do |type, bytes|
      assert_equal type, SNIFF.content_type(bytes), type
    end
  end

  def test_the_older_gif_signature
    assert_equal "image/gif", SNIFF.content_type("GIF87a\x01\x00".b)
  end

  def test_unknown_or_too_short_bytes_have_no_type
    ["", "hello", "\x89PNG".b, "RIFF\x24\x00\x00\x00WAVEfmt ".b, "\xFF\xD8".b, "%PD"].each do |bytes|
      assert_nil SNIFF.content_type(bytes), bytes.inspect
    end
  end

  def test_html_and_svg_have_no_type
    ["<!doctype html><html><body>", "<svg xmlns=\"http://www.w3.org/2000/svg\">"].each do |bytes|
      assert_nil SNIFF.content_type(bytes), bytes
    end
  end

  def test_an_ogg_stream_that_is_not_opus_is_not_audio_ogg
    vorbis = self.class.ogg_page("\x01vorbis\x00\x00\x00\x00\x02\x44\xAC\x00\x00".b)

    assert_nil SNIFF.content_type(vorbis)
    assert_nil SNIFF.content_type("OggS\x00\x02".b)
  end

  def test_opus_after_a_longer_segment_table
    page = self.class.ogg_page(OPUS_HEAD, segments: [255, 255, 255, 19])

    assert_equal "audio/ogg", SNIFF.content_type(page)
  end

  def test_only_the_first_64_bytes_count
    late_png = ("\x00" * 64).b + FIXTURES.fetch("image/png")

    assert_nil SNIFF.content_type(late_png)
    assert_equal "image/png", SNIFF.content_type(FIXTURES.fetch("image/png") + ("\x00" * 10_000).b)
  end

  def test_range_reads_64_bytes
    assert_equal 0..63, SNIFF::RANGE
  end

  def test_takes_any_encoding
    assert_equal "application/pdf", SNIFF.content_type("%PDF-1.4".encode("UTF-8"))
    assert_equal "image/jpeg", SNIFF.content_type("\xFF\xD8\xFF\xE0".dup.force_encoding("UTF-8"))
  end

  def test_refuses_what_is_not_a_string
    [nil, 42, [0x89]].each do |bytes|
      assert_raises(ArgumentError) { SNIFF.content_type(bytes) }
      assert_raises(ArgumentError) { SNIFF.refuse_svg!(bytes) }
    end
  end

  def test_refuse_svg_refuses_svg_and_xml
    [
      "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script>",
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg>",
      "\xEF\xBB\xBF<svg>".b,
      "  \n\t<SVG onload=\"alert(1)\">",
      "<!-- Generator: Adobe Illustrator --><svg>",
      "<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"\"><svg>",
      "<?XML version=\"1.0\"?>",
    ].each do |bytes|
      assert_raises(Monk::Storage::UnsafeContentError, bytes) { SNIFF.refuse_svg!(bytes) }
    end
  end

  def test_refuse_svg_lets_everything_else_through
    (FIXTURES.values + ["", "<!doctype html><html>", "plain text"]).each do |bytes|
      assert_same bytes, SNIFF.refuse_svg!(bytes)
    end
  end

  def test_refuse_svg_ignores_markers_past_the_first_64_bytes
    jpeg_with_xmp = "#{FIXTURES.fetch("image/jpeg")}#{"\x00" * 64}<?xpacket?><?xml version=\"1.0\"?>"

    assert_same jpeg_with_xmp, SNIFF.refuse_svg!(jpeg_with_xmp)
  end

  def test_works_inside_a_ractor
    png = FIXTURES.fetch("image/png")
    result = Ractor.new(png) do |bytes|
      sniff = Monk::Storage::Sniff
      begin
        sniff.refuse_svg!("<svg>")
      rescue Monk::Storage::UnsafeContentError
        [sniff.content_type(bytes), :refused]
      end
    end.value

    assert_equal ["image/png", :refused], result
  end
end
