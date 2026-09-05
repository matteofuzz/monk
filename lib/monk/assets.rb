require "digest"

require_relative "freeze_hooks"

module Monk
  # Static files -- CSS, vanilla JS, images, fonts -- served by Monk
  # itself out of a manifest built once at Boot and frozen, so a worker
  # Ractor reads bodies and ETags by reference and never touches the
  # filesystem or any mutable cache.
  #
  # One property worth naming: in production a lookup is an exact-match
  # fetch of a path enumerated at boot, so path traversal isn't
  # defended against, it's structurally impossible -- "/../../etc/passwd"
  # simply isn't a key. Development does hit the disk (so an edited file
  # shows up on the next request, no restart) and is the only mode that
  # needs the containment check in #disk_entry.
  module Assets
    DEFAULT_ROOT = "public".freeze

    # Ractor.make_shareable, not just #freeze: Hash#freeze only freezes the
    # hash object itself, not the String keys/values inside it, so a plain
    # `{ ... }.freeze` here is still rejected as unshareable the moment a
    # worker Ractor reads it -- exactly what #content_type does from
    # #disk_entry on every static-asset request in development.
    TEXT_TYPES = Ractor.make_shareable({
      ".css" => "text/css",
      ".js" => "text/javascript",
      ".mjs" => "text/javascript",
      ".html" => "text/html",
      ".json" => "application/json",
      ".svg" => "image/svg+xml",
      ".txt" => "text/plain",
      ".xml" => "application/xml",
      ".map" => "application/json",
    })

    BINARY_TYPES = Ractor.make_shareable({
      ".png" => "image/png",
      ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".gif" => "image/gif",
      ".webp" => "image/webp",
      ".avif" => "image/avif",
      ".ico" => "image/x-icon",
      ".woff" => "font/woff",
      ".woff2" => "font/woff2",
      ".ttf" => "font/ttf",
      ".otf" => "font/otf",
      ".pdf" => "application/pdf",
      ".wasm" => "application/wasm",
    })

    FALLBACK_TYPE = "application/octet-stream".freeze
    REVALIDATE = "public, max-age=0, must-revalidate".freeze
    IMMUTABLE = "public, max-age=31536000, immutable".freeze
    NO_CACHE = "no-cache".freeze

    class << self
      # Plain readers over eagerly-initialized ivars, never `@x ||= ...`:
      # a lazy reader writes on first access, and writing a module ivar
      # from a non-main Ractor is an isolation error. `production?` is
      # settled once at Boot for the same family of reasons -- ENV is
      # main-Ractor state, so a per-request read from a worker is a
      # hazard. `assets false` sets root to false and disables serving.
      attr_reader :root, :manifest
      attr_writer :root

      def enabled?
        !!root
      end

      def production?
        @production
      end

      # A Rack response for a GET/HEAD of a known asset, or nil so the
      # request falls through to routing. Called from Base#dispatch before
      # route matching, which is the conventional order (it's where
      # Rack::Static sits) and keeps a splat route from shadowing a
      # stylesheet.
      def response(env)
        return nil unless enabled?

        verb = env["REQUEST_METHOD"]
        return nil unless verb == "GET" || verb == "HEAD"

        entry = lookup(env["PATH_INFO"].to_s)
        return nil unless entry

        headers = {
          "content-type" => entry[:type],
          "etag" => entry[:etag],
          "cache-control" => cache_control(env, entry),
        }

        return [304, headers, []] if fresh?(env, entry)
        return [200, headers.merge("content-length" => entry[:body].bytesize.to_s), []] if verb == "HEAD"

        [200, headers, [entry[:body]]]
      end

      # The URL to link an asset by. In production it carries a `?v=`
      # digest, so a stamped request can be cached for a year; in
      # development it doesn't, because the boot-time digest goes stale
      # the moment the file is edited and a cached stylesheet is exactly
      # what you don't want while editing one.
      def path_for(path)
        return path unless production?

        entry = manifest[path]
        entry ? "#{path}?v=#{entry[:digest]}" : path
      end

      # Called from Base#freeze! (Seam B), via Monk.freeze_hooks.
      def freeze_registry!
        @production = ENV["MONK_ENV"] == "production"
        @manifest = Ractor.make_shareable(build_manifest)
        # #root is read on every request (#enabled?, and the disk lookup
        # in development). Left unfrozen, reading it from a worker Ractor
        # raises Ractor::IsolationError before the manifest is even
        # consulted.
        @root = root.freeze
      end

      # Test-only.
      def reset!
        @root = DEFAULT_ROOT
        @manifest = {}
        @production = false
      end

      def content_type(path)
        extension = File.extname(path).downcase
        return "#{TEXT_TYPES[extension]}; charset=utf-8" if TEXT_TYPES.key?(extension)

        BINARY_TYPES.fetch(extension, FALLBACK_TYPE)
      end

      private

      def build_manifest
        return {} unless enabled? && Dir.exist?(root)

        Dir.glob("**/*", base: root).each_with_object({}) do |relative, manifest|
          path = File.join(root, relative)
          next unless File.file?(path)

          manifest["/#{relative}"] = entry_for(relative, File.binread(path))
        end
      end

      def lookup(path)
        return manifest[path] if production?

        disk_entry(path)
      end

      # Development only. PATH_INFO is not un-escaped here on purpose: an
      # encoded "%2e%2e" stays a literal, nonexistent filename, and a
      # decoded ".." is caught by the containment check below.
      def disk_entry(path)
        return nil if path.empty? || path.include?("\0")

        root_path = File.expand_path(root)
        full = File.expand_path(File.join(root_path, path.delete_prefix("/")))
        return nil unless full.start_with?("#{root_path}#{File::SEPARATOR}")
        return nil unless File.file?(full)

        entry_for(path, File.binread(full))
      end

      def entry_for(path, body)
        digest = Digest::SHA256.hexdigest(body)[0, 16]
        { type: content_type(path), digest: digest, etag: %("#{digest}"), body: body }
      end

      def fresh?(env, entry)
        env["HTTP_IF_NONE_MATCH"].to_s.split(",").any? { |candidate| candidate.strip == entry[:etag] }
      end

      def cache_control(env, entry)
        return NO_CACHE unless production?

        env["QUERY_STRING"].to_s.split("&").include?("v=#{entry[:digest]}") ? IMMUTABLE : REVALIDATE
      end
    end

    @root = DEFAULT_ROOT
    @manifest = {}
    @production = false

    Monk.freeze_hooks << self
  end
end
