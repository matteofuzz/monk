require "digest"
# Loaded here, at boot: left to Digest.const_missing it loads on the first
# put, and a worker Ractor storing another in parallel can catch it
# half-defined (test/digest_preload_test.rb).
require "digest/md5"
require "fileutils"
require "json"
require "securerandom"

module Monk
  module Storage
    module Backends
      # Local disk, the development and test default (file://storage/<env>)
      # and an explicit choice for one server with a persistent volume.
      # root is absolute, expanded at configure, so a worker Ractor never
      # depends on the current directory. secret signs the links of the
      # /_monk/storage routes (docs/adr/0018-storage-s3-compatible-direct-upload.md).
      #
      # It behaves like a bucket: an object's bytes are in
      # <root>/objects/<key>~ and its metadata (content type, size, MD5) in
      # <root>/meta/<key>~.json. The "~", which no key contains, keeps a
      # key's file apart from the directory of a longer key ("a" and
      # "a/b" both exist in a bucket). Writes go to a temporary file then
      # File.rename, so a reader never sees half an object. An object
      # exists once its metadata does.
      #
      # Inside this block a bare File is this class: the disk is ::File.
      File = Data.define(:root, :secret) do
        # Returns the key. body is a String, or an IO that responds to size,
        # read and rewind (File, Tempfile, StringIO).
        def put(key, body, content_type: Input::DEFAULT_CONTENT_TYPE)
          Input.content_type!(content_type)
          Input.body!(body)
          object = path_for("objects", key, "~")
          meta = path_for("meta", key, "~.json")

          md5, size = write_atomically(object) { |out| copy_body(body, out) }
          write_atomically(meta) do |out|
            out.write(JSON.generate(content_type: content_type, byte_size: size, etag: md5))
          end
          key
        rescue SystemCallError, IOError => e
          raise RequestError, "file storage put #{key} failed: #{e.class}: #{e.message}"
        end

        # The bytes, as a frozen binary String. range: is a Range of byte
        # offsets (0..15 for the first 16 bytes); a range past the end gives
        # what's left, possibly "". A missing key raises NotFoundError.
        def get(key, range: nil)
          span = Input.byte_span(range) if range
          path = path_for("objects", key, "~")
          meta = read_meta(key) or raise NotFoundError, "no stored object #{key.inspect}"
          bytes = span ? read_span(path, span, meta[:byte_size]) : ::File.binread(path)
          bytes.freeze
        rescue Errno::ENOENT
          raise NotFoundError, "no stored object #{key.inspect}"
        rescue SystemCallError, IOError => e
          raise RequestError, "file storage get #{key} failed: #{e.class}: #{e.message}"
        end

        # A Storage::Object, or nil when the key is missing.
        def head(key)
          meta = read_meta(key) or return nil
          Storage::Object.new(key: key, byte_size: meta[:byte_size], content_type: meta[:content_type],
            etag: meta[:etag],)
        rescue SystemCallError, IOError => e
          raise RequestError, "file storage head #{key} failed: #{e.class}: #{e.message}"
        end

        # Idempotent, like S3: deleting a missing key is not an error.
        def delete(key)
          meta = path_for("meta", key, "~.json")
          object = path_for("objects", key, "~")
          ::FileUtils.rm_f(meta)
          ::FileUtils.rm_f(object)
          nil
        rescue SystemCallError, IOError => e
          raise RequestError, "file storage delete #{key} failed: #{e.class}: #{e.message}"
        end

        # Returns to. A missing from raises NotFoundError.
        def copy(from, to)
          source = path_for("objects", from, "~")
          target = path_for("objects", to, "~")
          target_meta = path_for("meta", to, "~.json")
          meta = read_meta(from) or raise NotFoundError, "no stored object #{from.inspect}"
          return to if source == target

          write_atomically(target) { |out| ::File.open(source, "rb") { |input| ::IO.copy_stream(input, out) } }
          write_atomically(target_meta) { |out| out.write(JSON.generate(meta)) }
          to
        rescue Errno::ENOENT
          raise NotFoundError, "no stored object #{from.inspect}"
        rescue SystemCallError, IOError => e
          raise RequestError, "file storage copy #{from} -> #{to} failed: #{e.class}: #{e.message}"
        end

        # A signed download link, the same for every call within one
        # cache_window, so the browser's cache works: valid until the end
        # of the window plus expires_in (docs/plan-storage.md decision 9).
        def url(key, expires_in:, cache_window:, now: Time.now.to_i)
          Key.validate!(key)
          Input.link_times!(expires_in: expires_in, cache_window: cache_window)
          window_start = now - (now % cache_window)
          link({ m: "GET", k: key, e: window_start + cache_window + expires_in })
        end

        # A signed upload link for a browser, with the length and content
        # type inside it.
        def presigned_put(key, content_type:, byte_size:, expires_in:, now: Time.now.to_i)
          Key.validate!(key)
          Input.content_type!(content_type)
          Input.byte_size!(byte_size)
          Input.link_times!(expires_in: expires_in, cache_window: 1)
          url = link({ m: "PUT", k: key, e: now + expires_in, l: byte_size, t: content_type })
          Upload.new(url: url, headers: { "Content-Type" => content_type, "Content-Length" => byte_size.to_s }.freeze)
        end

        # The /_monk/storage PUT: stores input (rack.input, read once) as
        # key, if it holds exactly byte_size bytes. Returns the MD5, or nil
        # when the length is wrong, and then stores nothing.
        def receive(key, input, content_type:, byte_size:)
          object = path_for("objects", key, "~")
          meta = path_for("meta", key, "~.json")

          md5 = write_atomically(object) do |out|
            digest, size = copy_at_most(input, out, byte_size)
            return nil unless size == byte_size

            digest
          end
          write_atomically(meta) do |out|
            out.write(JSON.generate(content_type: content_type, byte_size: byte_size, etag: md5))
          end
          md5
        rescue SystemCallError, IOError => e
          raise RequestError, "file storage upload #{key} failed: #{e.class}: #{e.message}"
        end

        # Never print the secret -- a backend ends up in logs and exception
        # messages more easily than anyone intends (same as Mail's SMTP).
        def inspect
          "#<#{self.class.name} file://#{root}>"
        end
        alias_method :to_s, :inspect

        private

        # The key is validated first, then the path is checked to stay under
        # root -- the Assets#disk_entry containment check -- and to go
        # through no symbolic link below root, which could point anywhere.
        def path_for(area, key, suffix)
          Key.validate!(key)
          base = ::File.join(root, area)
          full = ::File.expand_path("#{key}#{suffix}", base)
          unless full.start_with?("#{base}/")
            raise InvalidKeyError,
              "storage key #{key.inspect} resolves outside #{base}"
          end

          refuse_symlinks!(key, base, full)
          full
        end

        def refuse_symlinks!(key, base, full)
          path = base
          [nil, *full.delete_prefix("#{base}/").split("/")].each do |segment|
            path = ::File.join(path, segment) if segment
            next unless ::File.symlink?(path)

            raise InvalidKeyError, "storage key #{key.inspect} goes through a symbolic link (#{path})"
          end
        end

        def read_meta(key)
          JSON.parse(::File.read(path_for("meta", key, "~.json")), symbolize_names: true)
        rescue Errno::ENOENT
          nil
        end

        def read_span(path, span, size)
          first, last = span
          last = size - 1 if last.nil? || last >= size
          return "".b if first >= size

          ::File.open(path, "rb") do |file|
            file.seek(first)
            file.read(last - first + 1) || "".b
          end
        end

        # Yields a binary IO on a temporary file next to path, then renames
        # it into place. Returns the block's result.
        def write_atomically(path, &)
          ::FileUtils.mkdir_p(::File.dirname(path))
          temporary = "#{path}#{SecureRandom.hex(8)}.tmp"
          result = ::File.open(temporary, "wb", &)
          ::File.rename(temporary, path)
          result
        ensure
          ::FileUtils.rm_f(temporary) if temporary && ::File.exist?(temporary)
        end

        def link(payload)
          "#{ROUTE_PREFIX}#{Token.sign(payload, secret)}"
        end

        # Reads at most limit + 1 bytes, enough to tell a body that's too
        # long. Returns [md5 hex, bytes read].
        def copy_at_most(input, out, limit)
          md5 = Digest::MD5.new
          size = 0
          while size <= limit && (chunk = input.read([Input::CHUNK_BYTES, limit + 1 - size].min))
            out.write(chunk)
            md5 << chunk
            size += chunk.bytesize
          end
          [md5.hexdigest, size]
        end

        # Returns [md5 hex, bytes written].
        def copy_body(body, out)
          md5 = Digest::MD5.new
          if body.is_a?(String)
            out.write(body)
            md5 << body
            return [md5.hexdigest, body.bytesize]
          end

          body.rewind
          size = 0
          while (chunk = body.read(Input::CHUNK_BYTES))
            out.write(chunk)
            md5 << chunk
            size += chunk.bytesize
          end
          [md5.hexdigest, size]
        end
      end
    end
  end
end
