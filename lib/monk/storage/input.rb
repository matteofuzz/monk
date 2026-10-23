module Monk
  module Storage
    # Checks on the arguments both backends take, so they refuse the same
    # input the same way. Keys have their own module (Key).
    module Input
      DEFAULT_CONTENT_TYPE = "application/octet-stream".freeze
      CHUNK_BYTES = 64 * 1024
      # type/subtype with optional parameters, and nothing that could end a
      # header line.
      CONTENT_TYPE = %r{\A[a-z0-9][a-z0-9!\#$&^_.+-]*/[a-z0-9][a-z0-9!\#$&^_.+-]*(;[ \t]*[ -~]*)?\z}i

      module_function

      def content_type!(value)
        return value if value.is_a?(String) && value.match?(CONTENT_TYPE)

        raise ArgumentError, "content_type: must be a MIME type such as \"image/png\", not #{value.inspect}"
      end

      # A String, or an IO the backend can measure, read, and read again
      # (S3 hashes the body before sending it).
      def body!(body)
        return body if body.is_a?(String)
        return body if %i[size read rewind].all? { |name| body.respond_to?(name) }

        raise ArgumentError,
          "a stored body is a String or an IO that responds to size, read and rewind (File, Tempfile, " \
          "StringIO), not #{body.class}; write a pipe to a Tempfile first"
      end

      # A Range of byte offsets -> [first, last], last nil for "to the end".
      def byte_span(range)
        first = range.begin if range.is_a?(Range)
        last = range.end if range.is_a?(Range)
        unless first.is_a?(Integer) && first >= 0 && (last.nil? || last.is_a?(Integer))
          raise ArgumentError, "range: is a Range of byte offsets from 0, e.g. 0..15, not #{range.inspect}"
        end

        last -= 1 if last && range.exclude_end?
        raise ArgumentError, "range: #{range.inspect} is empty" if last && last < first

        [first, last]
      end
    end
  end
end
