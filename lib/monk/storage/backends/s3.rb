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
      S3 = Data.define(:bucket, :endpoint, :region, :access_key, :secret_key, :path_style, :tls) do
        def initialize(bucket:, endpoint:, region:, access_key:, secret_key:, path_style: false, tls: true)
          super
        end

        # Never print the secret key -- a backend ends up in logs and
        # exception messages more easily than anyone intends.
        def inspect
          "#<#{self.class.name} s3://#{access_key}:***@#{bucket} #{tls ? "https" : "http"}://#{endpoint} " \
            "region=#{region}#{" path_style" if path_style}>"
        end
        alias_method :to_s, :inspect
      end
    end
  end
end
