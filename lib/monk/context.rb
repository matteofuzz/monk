require "json"
require "uri"

require_relative "views"
require_relative "assets"

module Monk
  # The base of Context#head_tags: no tags. A module's helpers, included
  # into Context after this, add theirs with `def head_tags = super + [...]`
  # (Monk::Live::Helpers does), so a layout's <%= monk_head %> renders
  # every loaded module's tags and adding a module never edits the layout
  # (docs/adr/0017).
  module HeadTags
    def head_tags = []
  end

  class Context
    include Monk::Views::Compiled
    include Monk::HeadTags

    # Frozen once here: as literals in #render, the key was a new String
    # for every template rendered, partials included.
    CONTENT_TYPE = "content-type".freeze
    HTML_CONTENT_TYPE = "text/html; charset=utf-8".freeze

    attr_reader :params, :env, :headers
    attr_accessor :status

    # Internal: true while a template is rendering, so the default layout
    # wraps the page once and not every partial it renders.
    attr_accessor :rendering

    def initialize(params, env = {}, status: 200)
      @params = params
      @env = env
      @status = status
      @headers = {}
      @rendering = false
    end

    def header(name)
      env["HTTP_#{name.upcase.tr("-", "_")}"]
    end

    def halt(status, body = "")
      throw :monk_halt, [status, headers, [body]]
    end

    # Only to this app, unless the route says otherwise: a location built
    # from a param (`redirect(params[:return_to])`) could otherwise send
    # the browser to another site that looks like this one. A path
    # ("/notes", "notes/1") or an http(s) URL on this request's Host is
    # this app; anything else raises, a bug to fix, not a page to show.
    # `allow_other_host: true` is for a location the app built itself,
    # such as a Monk::Storage.url.
    def redirect(location, status: 302, allow_other_host: false)
      unless allow_other_host || this_app?(location)
        raise UnsafeRedirectError, "redirect to #{location.inspect}: another host, or not a plain path " \
          "(allow_other_host: true if the app built it)"
      end

      headers["location"] = location
      throw :monk_halt, [status, headers, [""]]
    end

    def json(data)
      headers["content-type"] = "application/json"
      throw :monk_halt, [status, headers, [JSON.generate(data)]]
    end

    # Renders a template and *returns* the HTML, unlike #json and #halt,
    # which throw. That's what makes a partial work: a template rendering
    # another template is this same call, and a route block's return value
    # is already the response body.
    #
    # Data reaches a template two ways, both zero-machinery: ivars set in
    # the route (the route block, the template and the layout all run with
    # `self` bound to this same Context), and the `locals` hash passed
    # here, which is what a partial rendered inside a loop wants.
    def render(name, layout: :default, **locals)
      headers[CONTENT_TYPE] ||= HTML_CONTENT_TYPE
      Monk::Views.render(self, name, locals, layout: layout)
    end

    def h(value)
      Monk::Views.h(value)
    end

    # Marks a string as already-safe, so the implicit escaping around
    # every `<%= %>` leaves it alone.
    def raw(value)
      Monk::Views::Raw.new(value.to_s)
    end

    def asset_path(path)
      Monk::Assets.path_for(path)
    end

    # Every loaded module's <head> tags, one per line, for the layout:
    #   <head> ... <%= monk_head %> </head>
    # Each tag is built by Monk, which escapes what it interpolates.
    def monk_head
      raw(head_tags.join("\n"))
    end

    # Same frozen values Monk::Settings[] reads, e.g. `settings[:api_key]`
    # -- returns the module itself rather than duplicating its #[] here,
    # so an undeclared key raises the exact same way through either path.
    def settings
      Monk::Settings
    end

    private

    # Browsers forgive what URI doesn't: they drop tabs and newlines, read
    # "\\" as "/" ("/\\evil.example" is "//evil.example") and "http:/x" as
    # "http://x". So: no control characters, spaces or backslashes at all,
    # and a scheme only with a host, this one. Empty (a nil param) is a
    # bug too.
    def this_app?(location)
      return false if location.to_s.empty? || location.to_s.match?(/[\x00-\x20\x7f\\]/)

      uri = URI.parse(location.to_s)
      return uri.host.nil? if uri.scheme.nil?
      return false unless %w[http https].include?(uri.scheme) && uri.host

      authority = uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"
      authority == env["HTTP_HOST"]
    rescue URI::InvalidURIError
      false
    end
  end
end
