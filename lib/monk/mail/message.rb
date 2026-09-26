module Monk
  module Mail
    # One email, as a frozen value: built per request inside whichever
    # worker Ractor serves it, then handed to a transport without a copy
    # (docs/adr/0012-minimal-built-in-mailer.md). Deeply frozen on
    # construction, so it's Ractor.shareable? even when the caller passed
    # mutable Strings or Arrays -- and later mutating those can't change it.
    #
    # Addresses are kept as given ("Name <addr>" or a bare "addr"); nothing
    # here parses them. `to` is always an Array, however it was passed.
    Message = Data.define(:from, :to, :subject, :text, :html, :reply_to) do
      def initialize(from:, to:, subject:, text: nil, html: nil, reply_to: nil)
        to = Array(to) unless to.nil?
        to&.each { |address| header!(:to, address) }
        raise InvalidMessageError, "to: needs at least one recipient" if to.nil? || to.empty?

        header!(:from, from)
        header!(:subject, subject)
        header!(:reply_to, reply_to) unless reply_to.nil?
        body!(:text, text)
        body!(:html, html)
        raise InvalidMessageError, "a message needs a text: or html: body (or both)" if text.nil? && html.nil?

        super(**Ractor.make_shareable(
          { from: from, to: to, subject: subject, text: text, html: html, reply_to: reply_to },
          copy: true,
        ))
      end

      # RFC 5322 wire format, ready for SMTP DATA or a raw-MIME API. date:,
      # message_id: and boundary: are generated when omitted; tests pin them.
      def to_mime(**) = MIME.build(self, **)

      # The bare addresses, for the SMTP envelope (MAIL FROM / RCPT TO).
      def envelope_from = Address.bare(from)
      def envelope_to = to.map { |address| Address.bare(address) }

      private

      # A CR or LF in a header value would let whoever controls it (say, a
      # user typing their email into a login form) inject headers of their
      # own -- a Bcc: to anyone. Rejected outright rather than stripped:
      # silently rewriting a recipient is worse than refusing it.
      def header!(field, value)
        string!(field, value)
        raise InvalidMessageError, "#{field}: can't be blank" if value.strip.empty?
        return unless value.match?(/[\r\n]/)

        raise InvalidMessageError, "#{field}: can't contain a line break (#{value.inspect})"
      end

      def body!(field, value)
        string!(field, value) unless value.nil?
      end

      def string!(field, value)
        return if value.is_a?(String)

        raise InvalidMessageError, "#{field}: must be a String, got #{value.inspect}"
      end
    end
  end
end
