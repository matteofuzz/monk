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

      def call(env)
        route, params = find_route(env["REQUEST_METHOD"], env["PATH_INFO"])
        return [404, {}, [""]] unless route

        context = Context.new(params)
        [200, {}, [context.instance_exec(&route[:block])]]
      end

      private

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
  end
end
