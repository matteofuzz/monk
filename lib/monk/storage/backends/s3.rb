require "net/http"

module Monk
  module Storage
    module Backends
      # Any S3-compatible service (Hetzner, R2, B2, AWS, MinIO): Monk names
      # no provider, only an endpoint and a region. A frozen value holding
      # settings only; the HTTP client is built for each call, inside the
      # Ractor making it, like Mail's SMTP and PG::Connection
      # (docs/adr/0018-storage-s3-compatible-direct-upload.md).
      #
      # endpoint is host[:port]. tls: false only for a local server
      # (endpoint=http://..., refused in staging and production).
      # path_style: true puts the bucket in the path instead of the host
      # name, which local servers need.
      S3 = Data.define(:bucket, :endpoint, :region, :access_key, :secret_key, :path_style, :tls,
        :open_timeout, :read_timeout,) do
        def initialize(bucket:, endpoint:, region:, access_key:, secret_key:, path_style: false, tls: true,
                       open_timeout: 5, read_timeout: 30)
          super
        end

        # Returns the key. body is a String, or an IO that responds to size,
        # read and rewind: its SHA-256 is computed first and signed, then it
        # is rewound and streamed, so it's read twice but never held in
        # memory (docs/plan-storage.md decision 11).
        def put(key, body, content_type: Input::DEFAULT_CONTENT_TYPE)
          Key.validate!(key)
          Input.content_type!(content_type)
          Input.body!(body)

          response = request("PUT", key, body: body, headers: { "content-type" => content_type })
          return key if response.is_a?(Net::HTTPSuccess)

          fail!("put", key, response)
        end

        # The bytes, as a frozen binary String. range: is a Range of byte
        # offsets; one that starts past the end gives "" (S3's 416).
        def get(key, range: nil)
          Key.validate!(key)
          headers = {}
          if range
            first, last = Input.byte_span(range)
            headers["range"] = "bytes=#{first}-#{last}"
          end

          response = request("GET", key, headers: headers)
          case response
          when Net::HTTPSuccess then response.body.to_s.b.freeze
          when Net::HTTPNotFound then raise NotFoundError, "no stored object #{key.inspect}"
          when Net::HTTPRangeNotSatisfiable then "".b.freeze
          else fail!("get", key, response)
          end
        end

        # A Storage::Object, or nil when the key is missing. A bucket that
        # doesn't grant ListBucket answers 403, not 404, for a missing key:
        # that's a RequestError here, as the credentials need fixing.
        def head(key)
          Key.validate!(key)
          response = request("HEAD", key)
          return nil if response.is_a?(Net::HTTPNotFound)

          fail!("head", key, response) unless response.is_a?(Net::HTTPSuccess)

          Storage::Object.new(key: key, byte_size: response["content-length"].to_i,
            content_type: response["content-type"], etag: response["etag"].to_s.delete('"'),)
        end

        # Idempotent: S3 answers 204 for a missing key too.
        def delete(key)
          Key.validate!(key)
          response = request("DELETE", key)
          return nil if response.is_a?(Net::HTTPSuccess)

          fail!("delete", key, response)
        end

        # Returns to. The content type is copied with the bytes. S3 can
        # answer 200 to a copy that failed, with an <Error> in the body, so
        # the body is checked too.
        def copy(from, to)
          Key.validate!(from)
          Key.validate!(to)
          source = SigV4.encode_path("/#{bucket}/#{from}")

          response = request("PUT", to, headers: { "x-amz-copy-source" => source })
          raise NotFoundError, "no stored object #{from.inspect}" if response.is_a?(Net::HTTPNotFound)
          return to if response.is_a?(Net::HTTPSuccess) && !response.body.to_s.include?("<Error>")

          fail!("copy #{from} ->", to, response)
        end

        # A signed GET link, the same for every call within one
        # cache_window: signed at the window's start, valid for the window
        # plus expires_in (docs/plan-storage.md decision 9).
        def url(key, expires_in:, cache_window:, now: Time.now.to_i)
          Key.validate!(key)
          Input.link_times!(expires_in: expires_in, cache_window: cache_window)
          query = SigV4.presign(method: "GET", path: path_for(key), headers: { "host" => host },
            expires_in: cache_window + expires_in, credentials: credentials, now: now - (now % cache_window),)
          "#{base_url}#{SigV4.encode_path(path_for(key))}?#{query}"
        end

        # A signed PUT link for a browser, with Content-Type and
        # Content-Length among its signed headers: the bucket refuses a
        # body of another length or type.
        def presigned_put(key, content_type:, byte_size:, expires_in:, now: Time.now.to_i)
          Key.validate!(key)
          Input.content_type!(content_type)
          Input.byte_size!(byte_size)
          headers = { "host" => host, "content-type" => content_type, "content-length" => byte_size.to_s }
          query = SigV4.presign(method: "PUT", path: path_for(key), headers: headers, expires_in: expires_in,
            credentials: credentials, now: now,)

          Upload.new(url: "#{base_url}#{SigV4.encode_path(path_for(key))}?#{query}",
            headers: { "Content-Type" => content_type, "Content-Length" => byte_size.to_s }.freeze,)
        end

        # Never print the secret key -- a backend ends up in logs and
        # exception messages more easily than anyone intends.
        def inspect
          "#<#{self.class.name} s3://#{access_key}:***@#{bucket} #{tls ? "https" : "http"}://#{endpoint} " \
            "region=#{region}#{" path_style" if path_style}>"
        end
        alias_method :to_s, :inspect

        private

        def credentials
          { access_key: access_key, secret_key: secret_key, region: region }
        end

        # Virtual-hosted (bucket.endpoint/key) unless path_style
        # (endpoint/bucket/key).
        def host
          path_style ? endpoint : "#{bucket}.#{endpoint}"
        end

        def path_for(key)
          path_style ? "/#{bucket}/#{key}" : "/#{key}"
        end

        def base_url
          "#{tls ? "https" : "http"}://#{host}"
        end

        # One signed request, on a connection opened for it in the calling
        # Ractor. Network and TLS failures become a RequestError, the
        # original as its #cause.
        def request(method, key, body: nil, headers: {})
          payload_hash = body ? Input.sha256(body) : SigV4::EMPTY_PAYLOAD
          signed = headers.merge("host" => host, "x-amz-content-sha256" => payload_hash)
          signed["content-length"] = body.size.to_s if body
          path = path_for(key)
          authorization = SigV4.sign_headers(method: method, path: path, headers: signed,
            payload_hash: payload_hash, credentials: credentials, now: Time.now.to_i,)

          http_request = Net::HTTPGenericRequest.new(method, !body.nil?, method != "HEAD", SigV4.encode_path(path),
            signed.merge(authorization).merge("accept-encoding" => "identity"),)
          attach(http_request, body) if body
          connection.start { |http| http.request(http_request) }
        rescue IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse,
               Net::ProtocolError => e
          raise RequestError, "S3 #{method} #{key} via #{host} failed: #{e.class}: #{e.message}"
        end

        def attach(http_request, body)
          if body.is_a?(String)
            http_request.body = body
          else
            body.rewind
            http_request.body_stream = body
          end
        end

        def connection
          http = Net::HTTP.new(host.sub(/:\d+\z/, ""), endpoint[/:(\d+)\z/, 1]&.to_i || (tls ? 443 : 80))
          http.use_ssl = tls
          http.open_timeout = open_timeout
          http.read_timeout = read_timeout
          http.write_timeout = read_timeout
          http
        end

        def fail!(operation, key, response)
          code = response.body.to_s[%r{<Code>([^<]*)</Code>}, 1]
          message = response.body.to_s[%r{<Message>([^<]*)</Message>}, 1]
          detail = [code, message].compact.join(": ")
          raise RequestError,
            "S3 #{operation} #{key} via #{host} failed: HTTP #{response.code}#{" #{detail}" unless detail.empty?}"
        end
      end
    end
  end
end
