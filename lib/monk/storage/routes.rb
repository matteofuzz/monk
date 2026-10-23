module Monk
  module Storage
    ROUTE_PREFIX = "/_monk/storage/".freeze

    # PUT and GET /_monk/storage/<token>: the file backend standing in for
    # a bucket's signed URLs, refusing what a bucket would refuse, the way
    # it would (docs/plan-storage.md decisions 7 and 8). Served whenever
    # the backend is file://, in any environment, since its links only
    # work if the routes exist.
    module Routes
      # Shareable, not only frozen: worker Ractors serve these routes.
      NOSNIFF = Ractor.make_shareable({ "x-content-type-options" => "nosniff" })
      RANGE = /\Abytes=(\d*)-(\d*)\z/

      module_function

      # A Rack response, or nil when the request isn't for these routes.
      def response(env, backend, now: Time.now.to_i)
        path = env["PATH_INFO"].to_s
        return nil unless backend.is_a?(Backends::File) && path.start_with?(ROUTE_PREFIX)

        payload = Token.verify(path.delete_prefix(ROUTE_PREFIX), backend.secret)
        return refuse(403, "signature doesn't match") unless payload
        return refuse(403, "link expired") unless payload[:e].is_a?(Integer) && payload[:e] > now
        return refuse(403, "this link is for #{payload[:m]}") unless env["REQUEST_METHOD"] == payload[:m]

        case payload[:m]
        when "PUT" then upload(env, backend, payload)
        when "GET" then download(env, backend, payload, now)
        else refuse(403, "signature doesn't match")
        end
      rescue InvalidKeyError
        refuse(403, "signature doesn't match")
      end

      # The browser's PUT. Content-Length and Content-Type are inside the
      # token, as in a presigned S3 PUT: another value is a 403. A body
      # shorter or longer than its Content-Length is a 400.
      def upload(env, backend, payload)
        return refuse(403, "Content-Length isn't the signed one") unless env["CONTENT_LENGTH"] == payload[:l].to_s
        return refuse(403, "Content-Type isn't the signed one") unless env["CONTENT_TYPE"] == payload[:t]

        md5 = backend.receive(payload[:k], env["rack.input"], content_type: payload[:t], byte_size: payload[:l])
        return refuse(400, "the body isn't Content-Length bytes") unless md5

        [200, NOSNIFF.merge("etag" => %("#{md5}")), []]
      end

      # The signed GET: the stored bytes, as their stored type, cached
      # privately until the link expires. A Range is answered with 206, as
      # a bucket does: Safari won't play <audio> or <video> without it.
      def download(env, backend, payload, now)
        object = backend.head(payload[:k])
        return refuse(404, "no such object") unless object

        headers = NOSNIFF.merge(
          "content-type" => object.content_type,
          "accept-ranges" => "bytes",
          "etag" => %("#{object.etag}"),
          "cache-control" => "private, max-age=#{payload[:e] - now}",
        )
        span = span(env["HTTP_RANGE"], object.byte_size)
        return whole(backend, payload[:k], headers) if span.nil?
        return refuse(416, "range not satisfiable", "content-range" => "bytes */#{object.byte_size}") if span == :none

        first, last = span
        bytes = backend.get(payload[:k], range: first..last)
        [206, headers.merge("content-range" => "bytes #{first}-#{last}/#{object.byte_size}",
          "content-length" => bytes.bytesize.to_s,), [bytes],]
      rescue NotFoundError
        refuse(404, "no such object")
      end

      def whole(backend, key, headers)
        bytes = backend.get(key)
        [200, headers.merge("content-length" => bytes.bytesize.to_s), [bytes]]
      end

      # One range of a Range header -> [first, last] within size; :none
      # when it can't be satisfied; nil to ignore the header and send the
      # whole object (no header, a syntax this doesn't read, several
      # ranges), as RFC 9110 allows.
      def span(header, size)
        match = header && RANGE.match(header)
        return nil unless match

        first, last = match.captures
        return nil if first.empty? && last.empty?

        if first.empty?
          suffix = last.to_i
          return :none if suffix.zero? || size.zero?

          return [[size - suffix, 0].max, size - 1]
        end

        first = first.to_i
        last = last.empty? ? size - 1 : [last.to_i, size - 1].min
        return nil if last < first && first < size
        return :none if first >= size

        [first, last]
      end

      def refuse(status, reason, extra = {})
        [status, NOSNIFF.merge("content-type" => "text/plain; charset=utf-8").merge(extra), ["#{reason}\n"]]
      end
    end
  end
end
