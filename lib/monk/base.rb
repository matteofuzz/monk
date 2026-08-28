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
        route, params = find_route(env["REQUEST_METHOD"], env["PATH_INFO"])
        return not_found_response unless route

        context = Context.new(params)
        catch(:monk_halt) do
          begin
            [200, {}, [context.instance_exec(context, &route[:block])]]
          rescue StandardError => e
            handler = error_handlers.find { |matcher, _| matcher.is_a?(Class) && e.is_a?(matcher) }
            if handler
              context.status = 500
              [500, {}, [context.instance_exec(context, &handler.last)]]
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

      def not_found_response
        handler = error_handlers.find { |matcher, _| matcher == 404 }
        return [404, {}, [""]] unless handler

        context = Context.new({}, status: 404)
        catch(:monk_halt) { [404, {}, [context.instance_exec(context, &handler.last)]] }
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
