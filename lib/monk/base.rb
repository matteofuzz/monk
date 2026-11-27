require "json"
require "uri"

require_relative "freeze_hooks"
require_relative "environment"
require_relative "params"

module Monk
  class Base
    VERBS = %w[GET POST PUT PATCH DELETE].freeze
    private_constant :VERBS

    EMPTY_ARRAY = [].freeze
    private_constant :EMPTY_ARRAY

    # How much of an unhandled exception's backtrace #log_exception
    # writes -- the same depth Monk::Jobs keeps for a failed job.
    BACKTRACE_LINES = 10
    private_constant :BACKTRACE_LINES

    # On every response, under the app's own headers: a route that sets
    # one (`headers["content-security-policy"] = ...`) replaces it.
    # nosniff: a browser never runs an upload or a JSON body as a script
    # or stylesheet. frame-ancestors: no other site can show this app in a
    # frame and trick a click on its forms. Referrer-Policy: another site
    # sees only the origin, never a path or a token in it.
    SECURITY_HEADERS = Ractor.make_shareable({
      "x-content-type-options" => "nosniff",
      "content-security-policy" => "frame-ancestors 'none'",
      "referrer-policy" => "strict-origin-when-cross-origin",
    })

    # Sec-Fetch-Site values a state-changing request may carry: from a page
    # of this same origin, or typed or bookmarked by the user ("none").
    SAME_ORIGIN_SITES = Ractor.make_shareable(%w[same-origin none])

    # "The process answers requests": a deploy's health check, and what the
    # offline client probes to know the app is back. Answered before
    # routing and logging, so no route, session or database runs, and a
    # check every few seconds doesn't fill the log. Not a deep check: a
    # slow database must not read as the app being down.
    UP_PATH = "/_monk/up".freeze
    UP_METHODS = Ractor.make_shareable(%w[GET HEAD])
    private_constant :SAME_ORIGIN_SITES

    OVERRIDABLE_VERBS = Ractor.make_shareable(%w[PATCH PUT DELETE])
    private_constant :OVERRIDABLE_VERBS

    # The largest form or JSON body Monk parses into params; past it, 413.
    MAX_PARSED_BODY = 1024 * 1024

    # Action name -> path suffix (appended to the resource path) and verb(s)
    # it dispatches on, for #resources. :update registers both PATCH and PUT --
    # PATCH is the canonical partial-update verb, PUT accepted too since
    # plenty of clients only ever send it for "update this resource".
    REST_ACTIONS = {
      index: { verbs: %w[GET], path: "" },
      new: { verbs: %w[GET], path: "/new" },
      create: { verbs: %w[POST], path: "" },
      show: { verbs: %w[GET], path: "/:id" },
      edit: { verbs: %w[GET], path: "/:id/edit" },
      update: { verbs: %w[PATCH PUT], path: "/:id" },
      destroy: { verbs: %w[DELETE], path: "/:id" },
    }.freeze
    private_constant :REST_ACTIONS

    class << self
      # `allow_cross_origin: true` turns off the cross-origin check
      # (#cross_origin?) for this one route: a webhook, say, posted by
      # another site's server -- which, being no browser, usually passes
      # anyway.
      VERBS.each do |verb|
        define_method(verb.downcase) do |path, allow_cross_origin: false, &block|
          routes << { verb: verb, path: path, block: block, allow_cross_origin: allow_cross_origin }
        end
      end

      def routes
        @routes ||= []
      end

      # EXPERIMENTAL: this is the one place Base's routing DSL departs
      # from "verb(path) { block }" -- a controller class plus a list of
      # action symbols, instead of a block. Not yet convinced that's the
      # right shape (see monk-consumer-test session notes); may be
      # reworked or removed rather than kept as-is.
      #
      # Registers a conventional set of REST routes rooted at `path` (e.g.
      # "/orders" -> "/orders", "/orders/new", "/orders/:id", ...), each
      # dispatching to `controller.new(context).public_send(action)`.
      # `actions` defaults to all seven (index/new/create/show/edit/
      # update/destroy); pass a subset to only wire up what `controller`
      # actually implements -- an action not listed here raises
      # ArgumentError immediately, rather than registering a route to a
      # method that doesn't exist.
      #
      # Built entirely on top of #get/#post/#put/#patch/#delete above --
      # no change to routing, dispatch, or freeze!, so an app that never
      # calls #resources is unaffected.
      def resources(path, controller, *actions)
        actions = REST_ACTIONS.keys if actions.empty?
        path = path.to_s.delete_prefix("/")

        actions.each do |action|
          mapping = REST_ACTIONS.fetch(action) do
            raise ArgumentError, "unknown REST action #{action.inspect} (known: #{REST_ACTIONS.keys.join(", ")})"
          end

          route = "/#{path}#{mapping[:path]}"
          mapping[:verbs].each { |verb| send(verb.downcase, route) { controller.new(self).public_send(action) } }
        end
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
          Ractor.make_shareable(route[:block])
        rescue ArgumentError, Ractor::IsolationError => e
          raise UnshareableRouteError, "#{route[:verb]} #{route[:path]} is not Ractor-shareable: #{e.message}"
        end

        error_handlers.each do |matcher, block|
          Ractor.make_shareable(block)
        rescue ArgumentError, Ractor::IsolationError => e
          raise UnshareableRouteError, "error handler for #{matcher.inspect} is not Ractor-shareable: #{e.message}"
        end

        define_block_methods!

        Monk.freeze!

        # Settled once here, not read from ENV per request in
        # #log_request: ENV is main-Ractor state, so a per-request read
        # from a worker Ractor is the same hazard Monk::Assets already
        # guards against the same way. Gates the $stdout echo only --
        # Monk::Log's file write is unconditional, every environment.
        @console_logging = Monk.env.development?

        index_routes!

        Ractor.make_shareable(routes)
        Ractor.make_shareable(@static_routes)
        Ractor.make_shareable(@dynamic_routes)
        Ractor.make_shareable(error_handlers)
        Ractor.make_shareable(@block_methods)
        self
      end

      def error(matcher, &block)
        error_handlers << [matcher, block]
      end

      def error_handlers
        @error_handlers ||= []
      end

      def call(env)
        return up(env) if env["PATH_INFO"] == UP_PATH

        freeze! unless Ractor.shareable?(routes)

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        status, headers, body = dispatch(env)
        log_request(env, status, start)
        [status, SECURITY_HEADERS.merge(headers), body]
      end

      private

      def up(env)
        unless UP_METHODS.include?(env["REQUEST_METHOD"])
          return [405, SECURITY_HEADERS.merge("allow" => UP_METHODS.join(", ")), []]
        end

        [204, SECURITY_HEADERS.merge("cache-control" => "no-store"), []]
      end

      def dispatch(env)
        # Assets before routes, the position Rack::Static would occupy in
        # front of the app -- so a catch-all splat route can't shadow a
        # stylesheet. The tradeoff, worth knowing: a route can't override
        # a path that exists as a file.
        asset = Monk::Assets.response(env)
        return asset if asset

        # The file storage backend's signed links, only when the app requires
        # monk/storage.
        stored = Monk::Storage.response(env) if defined?(Monk::Storage)
        return stored if stored

        # Query string, then the body's params on top (a form, or JSON),
        # then path params over both in Context.new below: the route's own
        # declared intent outranks anything a caller supplies. Before
        # routing, since a form's _method field picks the route.
        query, body = begin
          [Monk::Params.parse(env["QUERY_STRING"]), parse_body(env)]
        rescue Monk::Params::Error => e
          return [e.status, {}, [""]]
        end
        override_method(env, body)

        route, path_params = find_route(env["REQUEST_METHOD"], env["PATH_INFO"])
        return not_found_response(env) unless route
        return [403, {}, [""]] if cross_origin?(env) && !route[:allow_cross_origin]

        context = Context.new(query.merge(body).merge(path_params), env)
        catch(:monk_halt) do
          body = run_block(context, route[:block])
          [context.status, context.headers, [body]]
        rescue StandardError => e
          handler = error_handlers.find { |matcher, _| matcher.is_a?(Class) && e.is_a?(matcher) }
          log_exception(env, e, handled: !handler.nil?)
          if handler
            context.status = 500
            body = run_block(context, handler.last)
            [context.status, context.headers, [body]]
          else
            [500, { "content-type" => "application/json" }, ['{"error":"Internal Server Error"}']]
          end
        end
      end

      # Each route and error-handler block becomes a private method of
      # Context, once, here, rather than running through instance_exec on
      # every request. Same self, same ivars, same return value. On Ruby
      # 4.1 (preview1) an instance_exec in a worker Ractor stops that
      # Ractor's own, cheap GCs: its heap grows to GBs between global,
      # stop-the-world ones, and adding workers makes the app slower. A
      # method call doesn't, and on 4.0 the two cost the same. Blocks are
      # made shareable before this, so the methods run in any Ractor.
      #
      # A method's arity is strict, as a lambda's: a block with no
      # positional parameter is called with none, one that can take the
      # context (|c|, |c = nil|, |*args|) with it. A block that needs two
      # or more (instance_exec passes nil for the rest) keeps
      # instance_exec.
      def define_block_methods!
        @block_methods = {}.compare_by_identity
        blocks = routes.map { |route| route[:block] } + error_handlers.map(&:last)
        blocks.each_with_index do |block, i|
          name = :"__monk_block_#{object_id}_#{i}"
          Context.define_method(name, &block)
          Context.send(:private, name)

          takes_context = block.parameters.any? { |type, _| %i[req opt rest].include?(type) }
          arity = Context.instance_method(name).arity
          if !takes_context
            @block_methods[block] = [name, false].freeze
          elsif arity == 1 || arity.between?(-2, -1)
            @block_methods[block] = [name, true].freeze
          else
            Context.send(:remove_method, name)
          end
        end
      end

      def run_block(context, block)
        name, with_context = @block_methods[block]
        if name.nil?
          context.instance_exec(context, &block)
        elsif with_context
          context.__send__(name, context)
        else
          context.__send__(name)
        end
      end

      # The request line alone ("GET /x -> 500") says nothing about why.
      # Unhandled: an error, with the first backtrace lines. Handled by an
      # `error` block: the app chose the response, so one info line --
      # an error(NotFound) { halt 404 } shouldn't fill the log with ERRORs.
      def log_exception(env, error, handled:)
        line = "#{env["REQUEST_METHOD"]} #{env["PATH_INFO"]} raised #{error.class}: #{error.message}"
        if handled
          Monk::Log.info("#{line} (handled)")
        else
          trace = Array(error.backtrace).first(BACKTRACE_LINES).map { |frame| "\n  #{frame}" }
          Monk::Log.error("#{line}#{trace.join}")
        end
      end

      def log_request(env, status, start)
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)
        line = "#{Monk::Log.timestamp} #{env["REQUEST_METHOD"]} #{env["PATH_INFO"]} -> #{status} (#{duration_ms}ms)"

        if @console_logging
          $stdout.puts line
          # Each worker Ractor buffers $stdout independently; without an explicit
          # flush, lines only surface when the process exits, not in real time.
          $stdout.flush
        end

        Monk::Log.write("#{line}\n")
      end

      def not_found_response(env)
        handler = error_handlers.find { |matcher, _| matcher == 404 }
        return [404, {}, [""]] unless handler

        context = Context.new({}, env, status: 404)
        catch(:monk_halt) do
          body = run_block(context, handler.last)
          [context.status, context.headers, [body]]
        end
      end

      # A browser request changing state (every verb but GET) that comes
      # from another site: refused with 403 by #dispatch, on every route
      # unless it opts out. This is what stops CSRF, with or without auth
      # and with no token: a page on another site can still make the
      # browser send the request, but the browser says where it came from.
      # As Go's http.CrossOriginProtection: Sec-Fetch-Site, which every
      # current browser sends, then Origin against Host for older ones.
      # A request with neither is no browser's (curl, server to server)
      # and passes: it carries no cookie a victim's browser attached.
      def cross_origin?(env)
        return false if env["REQUEST_METHOD"] == "GET"

        site = env["HTTP_SEC_FETCH_SITE"]
        return !SAME_ORIGIN_SITES.include?(site) if site

        origin = env["HTTP_ORIGIN"]
        return false if origin.nil?

        origin.sub(%r{\A[a-z][a-z0-9+.-]*://}i, "") != env["HTTP_HOST"]
      end

      # An HTML form can only send GET and POST, so a POSTed form's
      # _method field (patch, put or delete) stands in for the verb, as
      # `resources`' update and destroy need. Only from a form body: never
      # the query string, never on another verb, never to GET.
      def override_method(env, body)
        return unless env["REQUEST_METHOD"] == "POST" && form_body?(env)

        verb = body[:_method].to_s.upcase
        env["REQUEST_METHOD"] = verb if OVERRIDABLE_VERBS.include?(verb)
      end

      def form_body?(env)
        env["CONTENT_TYPE"].to_s.start_with?("application/x-www-form-urlencoded")
      end

      # Files never come through here: they go straight to the bucket
      # (Monk::Storage), so a multipart body is refused rather than silently
      # read as no params.
      def parse_body(env)
        type = env["CONTENT_TYPE"].to_s
        if form_body?(env)
          Monk::Params.parse(read_body(env))
        elsif type.include?("application/json")
          parse_json(read_body(env))
        elsif type.start_with?("multipart/form-data")
          raise Monk::Params::Error.new("multipart bodies aren't read: upload files with Monk::Storage", status: 415)
        else
          {}
        end
      end

      # Kino already refuses a body over its max_body_size (50 MB by
      # default) with a 413; a body Monk parses has a much smaller cap, so
      # a worker never parses megabytes of a=1&a=1...
      def read_body(env)
        body = env["rack.input"]&.read(MAX_PARSED_BODY + 1).to_s
        if body.bytesize > MAX_PARSED_BODY
          raise Monk::Params::Error.new("body over #{MAX_PARSED_BODY} bytes", status: 413)
        end

        body
      end

      def parse_json(body)
        return {} if body.empty?

        parsed = JSON.parse(body, symbolize_names: true)
        raise Monk::Params::Error, "a JSON body must be an object" unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError => e
        raise Monk::Params::Error, e.message
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
