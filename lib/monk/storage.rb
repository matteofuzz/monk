require_relative "freeze_hooks"
require_relative "environment"
require_relative "storage/errors"
require_relative "storage/backends/file"
require_relative "storage/backends/s3"
require_relative "storage/url"

module Monk
  # Storing the files users send. Opt-in: require "monk/storage"
  # explicitly -- `require "monk"` alone does not load this. One
  # S3-compatible backend for every provider, local files in development
  # and test, and uploads that go from the browser straight to the bucket
  # (docs/adr/0018-storage-s3-compatible-direct-upload.md).
  module Storage
    # Signs the file backend's links in development and test when
    # STORAGE_SECRET is unset. Fixed, so a link built by bin/jobs also
    # works in the web process.
    DEVELOPMENT_SECRET = "monk-storage-development-secret".freeze

    class << self
      # Typically, in config/storage.rb:
      #
      #   Monk::Storage.configure(url: ENV["STORAGE_URL"], secret: ENV["STORAGE_SECRET"])
      #
      # url: picks the backend (file:// or s3://) and is parsed here, so a
      # bad one fails the boot. Unset or empty means file://storage/<env>
      # in development and test, and raises in staging and production: on
      # hosts whose disk is replaced on deploy, a silent fallback to local
      # files would lose every upload. secret: signs the file backend's
      # links, and is required with file:// outside development and test.
      # An S3 backend doesn't use it.
      def configure(url:, secret: nil)
        backend = backend_for(url)
        backend = backend.with(secret: secret_for(secret)) if backend.is_a?(Backends::File)

        @config = { backend: backend }
      end

      attr_reader :config

      # Called from Base#freeze! (Seam B), via Monk.freeze_hooks. Freezes
      # the value, not the module, same as Monk::Mail.freeze_registry! --
      # an unfrozen config Hash can't be read from a worker Ractor at all.
      def freeze_registry!
        @config = Ractor.make_shareable(@config)
      end

      # Test-only: drops the current config. Not part of the app-facing API.
      def reset!
        @config = nil
      end

      private

      def backend_for(url)
        return URL.parse(url) unless url.nil? || url.empty?
        return URL.parse("file://storage/#{Monk.env}") if Monk.env.development? || Monk.env.test?

        raise MissingStorageUrlError,
          "Monk::Storage.configure(url:) is empty and this isn't development or test (MONK_ENV=#{Monk.env}) -- " \
          "uploads would go to local files a deploy can replace. Set STORAGE_URL, e.g. " \
          "#{URL::S3_EXAMPLE}, or file:///path/on/a/volume if one server with a persistent volume is truly intended."
      end

      def secret_for(secret)
        return secret unless secret.nil? || secret.empty?
        return DEVELOPMENT_SECRET if Monk.env.development? || Monk.env.test?

        raise MissingStorageSecretError,
          "STORAGE_URL is file:// and Monk::Storage.configure(secret:) is empty (MONK_ENV=#{Monk.env}) -- " \
          "the file backend's links would be signed with a public value. Set STORAGE_SECRET to a random " \
          "value of its own (e.g. `ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`), not the auth secret."
      end
    end

    Monk.freeze_hooks << self
  end
end
