require "json"
require "uri"

require_relative "freeze_hooks"

module Monk
  class Base
    class << self
      %w[GET POST PUT PATCH DELETE].each do |verb|
        define_method(verb.downcase) do |path, &block|
          routes << { verb: verb, path: path, block: block }
        end
      end

      def routes
        @routes ||= []
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

        Ractor.make_shareable(routes)
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
        return if ENV["MONK_ENV"] == "production"

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

      def find_route(verb, path)
        path_segments = path.split("/")

        routes.each do |route|
          next unless route[:verb] == verb

          route_segments = route[:path].split("/")
          params = {}

          if route_segments.last == "*"
            prefix = route_segments[0...-1]
            next if path_segments.size < prefix.size
            next unless segments_match?(prefix, path_segments, params)

            params[:splat] = path_segments[prefix.size..].join("/")
            return [route, params]
          else
            next unless route_segments.size == path_segments.size
            next unless segments_match?(route_segments, path_segments, params)

            return [route, params]
          end
        end

        nil
      end

      def segments_match?(route_segments, path_segments, params)
        route_segments.each_with_index.all? do |segment, i|
          if segment.start_with?(":")
            params[segment[1..].to_sym] = path_segments[i]
            true
          else
            segment == path_segments[i]
          end
        end
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
