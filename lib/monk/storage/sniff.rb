module Monk
  module Storage
    # A file's type from its first bytes, since the Content-Type a client
    # sends can't be trusted. Defence in depth: the type a signed link
    # serves is the one the app signed into presigned_put from its allowed
    # list, and this catches a file whose bytes don't match it
    # (docs/history/plan-storage.md decision 12). At confirm, read only these
    # bytes:
    #
    #   head = Monk::Storage.get(key, range: Monk::Storage::Sniff::RANGE)
    #   Monk::Storage::Sniff.refuse_svg!(head)
    #   Monk::Storage::Sniff.content_type(head) # => "image/png" or nil
    module Sniff
      # 64 bytes, not 16: an Ogg page's header is 27 bytes plus one byte
      # per segment, so OpusHead starts at byte 28 on a usual first page.
      RANGE = 0..63

      PNG = "\x89PNG\r\n\x1A\n".b.freeze
      JPEG = "\xFF\xD8\xFF".b.freeze
      GIFS = Ractor.make_shareable(["GIF87a".b, "GIF89a".b])
      PDF = "%PDF-".b.freeze
      # Where an Ogg page's segment count sits; the segment table follows.
      OGG_SEGMENTS_AT = 26
      # Lowercased before matching, so <SVG and <?XML count too.
      SVG_MARKERS = Ractor.make_shareable(["<svg".b, "<?xml".b])

      module_function

      # "image/png", "image/jpeg", "image/gif", "image/webp", "audio/ogg"
      # (an Ogg stream whose first packet is OpusHead), "application/pdf",
      # or nil for anything else, an empty String included.
      def content_type(bytes)
        head = prefix(bytes)

        if head.start_with?(PNG) then "image/png"
        elsif head.start_with?(JPEG) then "image/jpeg"
        elsif head.start_with?(*GIFS) then "image/gif"
        elsif webp?(head) then "image/webp"
        elsif opus?(head) then "audio/ogg"
        elsif head.start_with?(PDF) then "application/pdf"
        end
      end

      # Raises UnsafeContentError when <svg or <?xml appears in the first
      # bytes: SVG can carry scripts, and an SVG may start with an XML
      # declaration, a comment or a doctype before its <svg. Only RANGE is
      # looked at, so the XMP metadata deep inside a JPEG or PDF doesn't
      # count. Returns bytes.
      def refuse_svg!(bytes)
        head = prefix(bytes).downcase
        if SVG_MARKERS.any? { |marker| head.include?(marker) }
          raise UnsafeContentError, "the file starts like SVG or XML, which can carry scripts; refused"
        end

        bytes
      end

      def prefix(bytes)
        unless bytes.is_a?(String)
          raise ArgumentError,
            "Sniff takes the file's first bytes as a String, not #{bytes.class}"
        end

        bytes.byteslice(RANGE).b
      end

      # RIFF, a 4-byte size, then WEBP.
      def webp?(head)
        head.start_with?("RIFF") && head.byteslice(8, 4) == "WEBP"
      end

      def opus?(head)
        return false unless head.start_with?("OggS") && head.bytesize > OGG_SEGMENTS_AT

        packet_at = OGG_SEGMENTS_AT + 1 + head.getbyte(OGG_SEGMENTS_AT)
        head.byteslice(packet_at, 8) == "OpusHead"
      end
      private_class_method :prefix, :webp?, :opus?
    end
  end
end
