require "json"

module Monk
  class Context
    attr_reader :params, :env
    attr_accessor :status

    def initialize(params, env = {}, status: 200)
      @params = params
      @env = env
      @status = status
    end

    def header(name)
      env["HTTP_#{name.upcase.tr("-", "_")}"]
    end

    def halt(status, body = "")
      throw :monk_halt, [status, {}, [body]]
    end

    def json(data)
      throw :monk_halt, [status, { "content-type" => "application/json" }, [JSON.generate(data)]]
    end
  end
end
