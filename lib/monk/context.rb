require "json"

require_relative "views"
require_relative "assets"

module Monk
  class Context
    include Monk::Views::Compiled

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

    def redirect(location, status: 302)
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
      headers["content-type"] ||= "text/html; charset=utf-8"
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
  end
end
