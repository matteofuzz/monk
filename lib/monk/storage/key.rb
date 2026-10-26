require "securerandom"

module Monk
  module Storage
    # Keys name objects in the bucket (or under the file backend's root).
    # Monk makes them random and never from a user's filename, which rules
    # out path traversal and keeps file names out of URLs
    # (docs/adr/0018-storage-s3-compatible-direct-upload.md).
    module Key
      # Lowercase only: macOS disks are case-insensitive, and the file
      # backend must not merge two keys a bucket keeps apart. A segment
      # can't start with a dot, so no "." or ".." segment, and no empty one.
      FORMAT = %r{\A[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)*\z}
      MAX_BYTES = 512

      module_function

      # "tmp/1f0c...": 128 random bits under prefix.
      def generate(prefix:)
        validate!(prefix)

        "#{prefix}/#{SecureRandom.hex(16)}"
      end

      # Runs on every call to either backend, so a key that would mean
      # something else on disk than in a bucket never reaches one.
      def validate!(key)
        raise InvalidKeyError, "a storage key is a String, not #{key.class}" unless key.is_a?(String)
        raise InvalidKeyError, "storage key is #{key.bytesize} bytes; at most #{MAX_BYTES}" if key.bytesize > MAX_BYTES
        unless key.match?(FORMAT)
          raise InvalidKeyError,
            "storage key #{key.inspect}: segments of a-z, 0-9, . _ and -, each starting with a letter or digit, " \
            "joined by / (e.g. from Monk::Storage.generate_key(prefix: \"tmp\"))"
        end

        key
      end
    end
  end
end
