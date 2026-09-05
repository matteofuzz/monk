require "json"
require "uri"

require_relative "freeze_hooks"
require_relative "environment"

module Monk
  class Base
    VERBS = %w[GET POST PUT PATCH DELETE].freeze
    private_constant :VERBS

    EMPTY_ARRAY = [].freeze
    private_constant :EMPTY_ARRAY

    class << self
      VERBS.each do |verb|
        define_method(verb.downcase) do |path, &block|
          routes << { verb: verb, path: path, block: block }
        end
      end

      def routes
        @routes ||= []
      end

      # Where .erb templates live (default "views"), relative to the
      # process's working directory and read at Boot.
      def views(dir)
        Monk::Views.root = dir
      end

      # Default layout template wrapped around every render, e.g.
      # layout "layouts/app". Individual renders opt out with
      # `render "x", layout: false`.
      def layout(name)
        Monk::Views.layout = name
      end

      # Where static files live (default "public"); `assets false`
      # disables serving them.
      def assets(dir)
        Monk::Assets.root = dir
      end

      def freeze!
        routes.each do |route|
          begin
            Ractor.make_shareable(route[:block])
          rescue ArgumentError => e
            raise UnshareableRouteError, "#{route[:verb]} #{route[:path]} is not Ractor-shareable: #{e.message}"
          end
        end

        error_handlers.each do |matcher, block|
          begin
            Ractor.make_shareable(block)
          rescue ArgumentError => e
            raise UnshareableRouteError, "error handler for #{matcher.inspect} is not Ractor-shareable: #{e.message}"
          end
        end

        Monk.freeze!

        # Settled once here, not read from ENV per request in
        # #log_request: ENV is main-Ractor state, so a per-request read
        # from a worker Ractor is the same hazard Monk::Assets already
        # guards against the same way.
        @quiet_logging = !Monk.env.development?

        index_routes!

        Ractor.make_shareable(routes)
        Ractor.make_shareable(@static_routes)
        Ractor.make_shareable(@dynamic_routes)
        Ractor.make_shareable(error_handlers)
        self
      end

      def error(matcher, &block)
        error_handlers << [matcher, block]
      end

      def error_handlers
        @error_handlers ||= []
      end

      def call(env)
        freeze! unless Ractor.shareable?(routes)

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        status, headers, body = dispatch(env)
        log_request(env, status, start)
        [status, headers, body]
      end

      private

      def dispatch(env)
        # Assets before routes, the position Rack::Static would occupy in
        # front of the app -- so a catch-all splat route can't shadow a
        # stylesheet. The tradeoff, worth knowing: a route can't override
        # a path that exists as a file.
        asset = Monk::Assets.response(env)
        return asset if asset

        route, path_params = find_route(env["REQUEST_METHOD"], env["PATH_INFO"])
        return not_found_response(env) unless route

        params = parse_params(env).merge(path_params)
        context = Context.new(params, env)
        catch(:monk_halt) do
          begin
            body = context.instance_exec(context, &route[:block])
            [200, context.headers, [body]]
          rescue StandardError => e
            handler = error_handlers.find { |matcher, _| matcher.is_a?(Class) && e.is_a?(matcher) }
            if handler
              context.status = 500
              body = context.instance_exec(context, &handler.last)
              [500, context.headers, [body]]
            else
              [500, { "content-type" => "application/json" }, ['{"error":"Internal Server Error"}']]
            end
          end
        end
      end

      def log_request(env, status, start)
        return if @quiet_logging

        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)
        $stdout.puts "#{env["REQUEST_METHOD"]} #{env["PATH_INFO"]} -> #{status} (#{duration_ms}ms)"
        # Each worker Ractor buffers $stdout independently; without an explicit
        # flush, lines only surface when the process exits, not in real time.
        $stdout.flush
      end

      def not_found_response(env)
        handler = error_handlers.find { |matcher, _| matcher == 404 }
        return [404, {}, [""]] unless handler

        context = Context.new({}, env, status: 404)
        catch(:monk_halt) do
          body = context.instance_exec(context, &handler.last)
          [404, context.headers, [body]]
        end
      end

      # Query string, then a JSON body on top (POST /auth/request's
      # redirect_to; a callback token as ?token=... instead of a path
      # segment -- PLAN-AUTH.md Phase 9 step 29). Path segment params
      # always win the final merge in #dispatch -- the route's own
      # declared intent outranks anything a caller supplies.
      def parse_params(env)
        parse_query_string(env["QUERY_STRING"]).merge(parse_json_body(env))
      end

      # URI.decode_www_form, not Rack::Utils.parse_nested_query -- the
      # latter memoizes an unfrozen QueryParser instance in a module ivar
      # (Rack::Utils.default_query_parser) the moment "rack/utils" loads,
      # in the main Ractor, and reading it back from a worker Ractor raises
      # Ractor::IsolationError regardless of which Ractor set it. A bug in
      # rack itself (not yet Ractor-safe), measured directly against a real
      # worker Ractor rather than assumed -- no nested/array query syntax,
      # consistent with Monk's minimal query surface elsewhere.
      def parse_query_string(query_string)
        return {} if query_string.to_s.empty?

        URI.decode_www_form(query_string).each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      end

      def parse_json_body(env)
        return {} unless env["CONTENT_TYPE"].to_s.include?("application/json")

        body = env["rack.input"]&.read.to_s
        return {} if body.empty?

        JSON.parse(body, symbolize_names: true)
      rescue JSON::ParserError
        {}
      end

      # Routes are static (literal path, no ":param" or trailing "*") in
      # the overwhelming common case, so freeze! (#index_routes!) splits
      # them into an O(1) exact-match table up front; only routes that
      # actually need segment-by-segment matching pay for it at request
      # time. Both structures hold the exact same route Hash objects that
      # `routes` does, so making `routes` shareable would freeze them too
      # -- but since they're not reachable *from* `routes`, they need
      # their own Ractor.make_shareable call in #freeze!.
      def index_routes!
        static = {}
        dynamic = {}
        VERBS.each do |verb|
          static[verb] = {}
          dynamic[verb] = []
        end

        routes.each do |route|
          segments = route[:path].split("/")
          route[:segments] = segments

          if segments.last == "*"
            route[:prefix_segments] = segments[0...-1]
            dynamic[route[:verb]] << route
          elsif segments.any? { |s| s.start_with?(":") }
            dynamic[route[:verb]] << route
          else
            static[route[:verb]][route[:path]] = route
          end
        end

        @static_routes = static
        @dynamic_routes = dynamic
      end

      def find_route(verb, path)
        static_route = @static_routes.dig(verb, path)
        return [static_route, {}] if static_route

        path_segments = path.split("/")

        (@dynamic_routes[verb] || EMPTY_ARRAY).each do |route|
          if route[:prefix_segments]
            prefix = route[:prefix_segments]
            next if path_segments.size < prefix.size
            next unless segments_match?(prefix, path_segments)

            params = extract_params(prefix, path_segments)
            params[:splat] = path_segments[prefix.size..].join("/")
            return [route, params]
          else
            route_segments = route[:segments]
            next unless route_segments.size == path_segments.size
            next unless segments_match?(route_segments, path_segments)

            return [route, extract_params(route_segments, path_segments)]
          end
        end

        nil
      end

      # Boolean-only: whether a candidate route matches is decided before
      # any params Hash is allocated, so a failed candidate costs nothing
      # beyond the comparisons themselves.
      def segments_match?(route_segments, path_segments)
        route_segments.each_with_index.all? do |segment, i|
          segment.start_with?(":") || segment == path_segments[i]
        end
      end

      def extract_params(route_segments, path_segments)
        params = {}
        route_segments.each_with_index do |segment, i|
          params[segment[1..].to_sym] = path_segments[i] if segment.start_with?(":")
        end
        params
      end
    end

    def call(env)
      self.class.call(env)
    end

    def freeze!
      self.class.freeze!
      self
    end
  end
end
