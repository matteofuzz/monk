require "uri"

module Monk
  module Storage
    # STORAGE_URL -> a backend value. Runs once, from Monk::Storage.configure
    # in the main Ractor at boot, so a malformed URL fails the boot rather
    # than the first upload (same posture as Monk::Mail::URL). Error
    # messages redact the secret key: the URL is a secret.
    module URL
      SUPPORTED = "file://, s3://".freeze
      S3_EXAMPLE = "s3://KEY:SECRET@bucket?endpoint=fsn1.your-objectstorage.com&region=fsn1".freeze
      S3_OPTIONS = %w[endpoint region path_style].freeze
      # S3's rule for bucket names that also work in a host name
      # (virtual-hosted addressing, the default).
      BUCKET = /\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/
      HOST = /\A[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:\d{1,5})?\z/

      module_function

      def parse(url)
        case url[%r{\A([a-z][a-z0-9+.-]*)://}i, 1]&.downcase
        when "file" then file(url)
        when "s3" then s3(url)
        else invalid!(url, "unsupported scheme; supported: #{SUPPORTED}")
        end
      end

      # file://storage/development (relative to the current directory) or
      # file:///var/lib/app/storage (absolute).
      def file(url)
        dir = url.sub(%r{\A[a-z]+://}i, "")
        invalid!(url, "missing directory, e.g. file://storage/production") if dir.empty?
        invalid!(url, "a directory takes no options") if dir.include?("?")

        Backends::File.new(root: File.expand_path(dir), secret: nil)
      end

      def s3(url)
        uri = URI.parse(url)
        options = s3_options(uri, url)
        endpoint, tls = endpoint(options["endpoint"], url)
        Backends::S3.new(
          bucket: bucket(uri, url),
          endpoint: endpoint,
          region: required(options, "region", url),
          access_key: credential(uri.user, "access key", url),
          secret_key: credential(uri.password, "secret key", url),
          path_style: path_style(options["path_style"], url),
          tls: tls,
        )
      rescue URI::InvalidURIError
        invalid!(url, "not a valid URL (percent-encode / @ : in the keys); expected e.g. #{S3_EXAMPLE}")
      end

      def s3_options(uri, url)
        options = URI.decode_www_form(uri.query || "").to_h
        unknown = options.keys - S3_OPTIONS
        invalid!(url, "unknown option(s) #{unknown.join(", ")}; supported: #{S3_OPTIONS.join(", ")}") if unknown.any?

        options
      end

      def bucket(uri, url)
        invalid!(url, "a port goes in endpoint=, not after the bucket") if uri.port
        invalid!(url, "nothing goes after the bucket but options") unless ["", "/"].include?(uri.path)

        name = uri.host.to_s
        invalid!(url, "missing bucket, e.g. #{S3_EXAMPLE}") if name.empty?
        invalid!(url, "bucket #{name.inspect}: 3-63 of a-z, 0-9, . and -") unless name.match?(BUCKET)

        name
      end

      # A bare host means HTTPS. http:// sends the credentials and every
      # body in clear: accepted for a local server (MinIO in Monk's own
      # suite), refused in staging and production.
      def endpoint(value, url)
        invalid!(url, "missing endpoint=, e.g. #{S3_EXAMPLE}") if value.nil? || value.empty?

        scheme = value[%r{\A([a-z]+)://}i, 1]&.downcase
        invalid!(url, "endpoint= must be https:// or http://") unless [nil, "https", "http"].include?(scheme)

        host = value.sub(%r{\A[a-z]+://}i, "").chomp("/")
        invalid!(url, "endpoint= must be a host, optionally with a port") unless host.match?(HOST)

        tls = scheme != "http"
        if !tls && (Monk.env.staging? || Monk.env.production?)
          invalid!(url, "endpoint=http:// sends the keys in clear; it's for a local server, " \
                        "not MONK_ENV=#{Monk.env}",)
        end

        [host.downcase, tls]
      end

      def path_style(value, url)
        case value
        when nil, "0" then false
        when "1" then true
        else invalid!(url, "path_style= must be 1 or 0")
        end
      end

      def required(options, name, url)
        value = options[name]
        invalid!(url, "missing #{name}=, e.g. #{S3_EXAMPLE}") if value.nil? || value.empty?

        value
      end

      # A secret with @, : or / in it has to be percent-encoded in the URL.
      def credential(component, name, url)
        invalid!(url, "missing #{name}, e.g. #{S3_EXAMPLE}") if component.nil? || component.empty?

        URI.decode_uri_component(component)
      end

      def invalid!(url, reason)
        raise InvalidStorageUrlError, "STORAGE_URL #{redact(url).inspect}: #{reason}"
      end

      def redact(url)
        url.to_s.sub(%r{(://[^:/@]*:)[^@/]*@}, '\1***@')
      end
    end
  end
end
