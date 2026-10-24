require "digest"
# Loaded here, at boot: left to Digest.const_missing it loads on the first
# signed request, and a worker Ractor signing another in parallel can
# catch it half-defined (test/digest_preload_test.rb).
require "digest/sha2"
require "openssl"

module Monk
  module Storage
    # AWS Signature Version 4, for the S3 backend: the Authorization header
    # of a request Monk sends, and the query string of a link a browser
    # uses (a presigned PUT, a signed GET). Pure functions of their
    # arguments, the time included, so they're tested against AWS's
    # published vectors without stubbing Time (docs/plan-storage.md
    # decision 10).
    #
    # Paths and query strings are encoded the S3 way: each byte outside
    # A-Z a-z 0-9 - _ . ~ as %XX, "/" kept in paths, and paths encoded once
    # and never normalized (S3 differs from other AWS services there).
    module SigV4
      ALGORITHM = "AWS4-HMAC-SHA256".freeze
      # The payload hash of a presigned link: the browser sends the body,
      # so it can't be signed in advance.
      UNSIGNED_PAYLOAD = "UNSIGNED-PAYLOAD".freeze
      EMPTY_PAYLOAD = Digest::SHA256.hexdigest("").freeze
      MAX_EXPIRES = 7 * 24 * 3600
      UNRESERVED = /[^A-Za-z0-9\-_.~]/

      module_function

      # The headers to add to a request: x-amz-date and authorization.
      # headers: are the ones to sign, host included (and
      # x-amz-content-sha256 for S3); their names may be in any case.
      # payload_hash: is the body's SHA-256 in hex. now: is a Unix time.
      def sign_headers(method:, path:, headers:, payload_hash:, credentials:, now:, query: {})
        date = timestamp(now)
        signed = canonical_headers(headers.merge("x-amz-date" => date))
        signature = signature(method, path, canonical_query(query), signed, payload_hash, credentials, date)
        {
          "x-amz-date" => date,
          "authorization" => "#{ALGORITHM} Credential=#{credentials[:access_key]}/#{scope(credentials, date)}, " \
                             "SignedHeaders=#{signed.keys.join(";")}, Signature=#{signature}",
        }
      end

      # The query string of a presigned link, signature last: the request's
      # own query: parameters, then the X-Amz-* ones. headers: are the ones
      # the client must send exactly (host, and for a presigned PUT
      # content-length and content-type).
      def presign(method:, path:, headers:, expires_in:, credentials:, now:, query: {},
                  payload_hash: UNSIGNED_PAYLOAD)
        unless expires_in.is_a?(Integer) && expires_in.between?(1, MAX_EXPIRES)
          raise ArgumentError, "a presigned link is valid 1 to #{MAX_EXPIRES} seconds, not #{expires_in.inspect}"
        end

        date = timestamp(now)
        signed = canonical_headers(headers)
        params = query.merge(
          "X-Amz-Algorithm" => ALGORITHM,
          "X-Amz-Credential" => "#{credentials[:access_key]}/#{scope(credentials, date)}",
          "X-Amz-Date" => date,
          "X-Amz-Expires" => expires_in.to_s,
          "X-Amz-SignedHeaders" => signed.keys.join(";"),
        )
        canonical = canonical_query(params)
        "#{canonical}&X-Amz-Signature=#{signature(method, path, canonical, signed, payload_hash, credentials, date)}"
      end

      def signature(method, path, query, headers, payload_hash, credentials, date)
        request = canonical_request(method, path, query, headers, payload_hash)
        OpenSSL::HMAC.hexdigest("SHA256", signing_key(credentials, date), string_to_sign(request, credentials, date))
      end

      def canonical_request(method, path, query, headers, payload_hash)
        [
          method,
          encode_path(path),
          query,
          headers.map { |name, value| "#{name}:#{value}\n" }.join,
          headers.keys.join(";"),
          payload_hash,
        ].join("\n")
      end

      def string_to_sign(canonical_request, credentials, date)
        [ALGORITHM, date, scope(credentials, date), Digest::SHA256.hexdigest(canonical_request)].join("\n")
      end

      def signing_key(credentials, date)
        key = "AWS4#{credentials[:secret_key]}"
        [date[0, 8], credentials[:region], credentials.fetch(:service, "s3"), "aws4_request"].each do |part|
          key = OpenSSL::HMAC.digest("SHA256", key, part)
        end
        key
      end

      def scope(credentials, date)
        "#{date[0, 8]}/#{credentials[:region]}/#{credentials.fetch(:service, "s3")}/aws4_request"
      end

      # Lowercase names, sorted; values trimmed, inner runs of spaces made one.
      def canonical_headers(headers)
        headers.to_h { |name, value| [name.to_s.downcase, value.to_s.strip.gsub(/\s+/, " ")] }.sort.to_h
      end

      def canonical_query(params)
        params.map { |name, value| [encode(name.to_s), encode(value.to_s)] }.sort
              .map { |name, value| "#{name}=#{value}" }.join("&")
      end

      def encode_path(path)
        path.split("/", -1).map { |segment| encode(segment) }.join("/")
      end

      def encode(text)
        text.b.gsub(UNRESERVED) { |byte| format("%%%02X", byte.ord) }
      end

      def timestamp(now)
        Time.at(now).utc.strftime("%Y%m%dT%H%M%SZ")
      end
    end
  end
end
