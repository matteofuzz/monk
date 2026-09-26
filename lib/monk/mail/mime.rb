require "securerandom"

module Monk
  module Mail
    # Renders a Message to RFC 5322 wire format -- what the `mail` gem
    # would do, cut down to Monk::Mail's scope: a text part, an HTML part,
    # or both as multipart/alternative. Bodies are UTF-8 and always base64
    # (never 7bit/quoted-printable), so any content survives any relay and
    # no line ever gets near the 998-octet limit. Header values that
    # aren't plain ASCII are RFC 2047 encoded words. Plain module
    # functions over frozen input, so it runs in any Ractor.
    module MIME
      CRLF = "\r\n".freeze
      MAX_LINE = 78
      # 42 bytes base64-encode to 56 chars; with the "=?UTF-8?B?" / "?="
      # wrapper that's a 68-char encoded word, under RFC 2047's 75, and
      # "Subject: " plus one of them still fits a 78-char line.
      WORD_BYTES = 42

      module_function

      def build(message, date: Time.now, message_id: nil, boundary: nil)
        message_id ||= "<#{SecureRandom.uuid}@#{domain(message.envelope_from)}>"
        headers = [
          "From: #{address_list([message.from], "From")}",
          "To: #{address_list(message.to, "To")}",
          ("Reply-To: #{address_list([message.reply_to], "Reply-To")}" if message.reply_to),
          "Subject: #{unstructured(message.subject, "Subject")}",
          "Date: #{date.strftime("%a, %d %b %Y %H:%M:%S %z")}",
          "Message-ID: #{message_id}",
          "MIME-Version: 1.0",
        ].compact

        parts = [
          (["text/plain", message.text] if message.text),
          (["text/html", message.html] if message.html),
        ].compact

        if parts.size == 1
          (headers + part(*parts.first)).join(CRLF)
        else
          boundary ||= "monk-#{SecureRandom.hex(16)}"
          head = headers + [%(Content-Type: multipart/alternative; boundary="#{boundary}"), "", ""]
          body = parts.map { |type, content| "--#{boundary}#{CRLF}#{part(type, content).join(CRLF)}" }
          head.join(CRLF) + body.join + "--#{boundary}--#{CRLF}"
        end
      end

      # A part's own headers, a blank line, then its base64 body (which
      # ends in CRLF).
      def part(type, content)
        body = utf8(content, type).gsub(/\r?\n/, CRLF)
        [
          "Content-Type: #{type}; charset=UTF-8",
          "Content-Transfer-Encoding: base64",
          "",
          [body].pack("m").gsub("\n", CRLF),
        ]
      end

      def address_list(addresses, name)
        rendered = addresses.map { |address| Address.header(utf8(address, name)) }
        one_line = rendered.join(", ")
        name.length + 2 + one_line.length <= MAX_LINE ? one_line : rendered.join(",#{CRLF} ")
      end

      # ASCII stays readable (folded at spaces when long); anything else,
      # or anything that could be mistaken for an encoded word, is encoded.
      def unstructured(value, name)
        value = utf8(value, name)
        return encode_words(value) if !value.ascii_only? || value.include?("=?")

        fold(value, name.length + 2)
      end

      # RFC 2047 "B" encoded words, split so none exceeds WORD_BYTES of
      # input -- and never inside a multibyte character, which would leave
      # both halves undecodable. Joined by folding whitespace, which
      # decoders drop between adjacent encoded words.
      def encode_words(value)
        chunks = value.each_char.with_object([+""]) do |char, acc|
          acc << +"" if acc.last.bytesize + char.bytesize > WORD_BYTES
          acc.last << char
        end
        chunks.map { |chunk| "=?UTF-8?B?#{[chunk].pack("m0")}?=" }.join("#{CRLF} ")
      end

      # Greedy wrap at spaces; a continuation line starts with one space.
      # A value that already fits is returned untouched, spacing and all.
      def fold(value, offset)
        return value if offset + value.length <= MAX_LINE

        lines = []
        current = nil
        value.split.each do |word|
          width = lines.empty? ? offset : 1
          if current && width + current.length + 1 + word.length > MAX_LINE
            lines << current
            current = word
          else
            current = current ? "#{current} #{word}" : word
          end
        end
        lines << current if current
        lines.join("#{CRLF} ")
      end

      def domain(address)
        address.include?("@") ? address.split("@").last : "localhost"
      end

      # Every piece of text goes out as UTF-8. A binary String is assumed
      # to be UTF-8 bytes; any other encoding is transcoded.
      def utf8(value, name)
        string = value.encoding == Encoding::BINARY ? value.dup.force_encoding(Encoding::UTF_8) : value.encode(Encoding::UTF_8)
        return string if string.valid_encoding?

        raise InvalidMessageError, "#{name} isn't valid UTF-8"
      rescue EncodingError
        raise InvalidMessageError, "#{name} can't be converted to UTF-8"
      end
    end
  end
end
