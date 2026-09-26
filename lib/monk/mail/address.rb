module Monk
  module Mail
    # Just enough address handling for what Monk::Mail sends: split
    # "Name <addr>" into its parts, and render one back into a header
    # value. Not an RFC 5322 parser -- groups, comments and quoted local
    # parts are out of scope (docs/adr/0012-minimal-built-in-mailer.md).
    module Address
      ANGLE = /\A\s*(.*?)\s*<([^<>]*)>\s*\z/
      # A display name made only of these goes out as-is; anything else
      # ASCII gets quoted, so a comma in "Doe, John" can't split one
      # recipient into two.
      PLAIN_PHRASE = %r{\A[A-Za-z0-9!#$%&'*+\-/=?^_`{|}~ ]+\z}

      module_function

      # "App <a@app.test>" -> ["App", "a@app.test"]; "a@app.test" -> [nil, "a@app.test"]
      def split(value)
        match = ANGLE.match(value)
        return [nil, value.strip] unless match

        name = match[1]
        [name.empty? ? nil : name, match[2].strip]
      end

      def bare(value) = split(value).last

      def header(value)
        name, address = split(value)
        name ? "#{phrase(name)} <#{address}>" : address
      end

      def phrase(name)
        return name if name.length >= 2 && name.start_with?('"') && name.end_with?('"')
        return MIME.encode_words(name) unless name.ascii_only?
        return name if name.match?(PLAIN_PHRASE)

        %("#{name.gsub(/["\\]/) { |char| "\\#{char}" }}")
      end
    end
  end
end
