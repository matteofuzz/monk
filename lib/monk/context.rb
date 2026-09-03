require "json"

module Monk
  class Context
    attr_reader :params, :env, :headers
    attr_accessor :status

    def initialize(params, env = {}, status: 200)
      @params = params
      @env = env
      @status = status
      @headers = {}
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
  end
end
