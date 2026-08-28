require "json"

module Monk
  class Context
    attr_reader :params

    def initialize(params)
      @params = params
    end

    def halt(status, body = "")
      throw :monk_halt, [status, {}, [body]]
    end

    def json(data)
      throw :monk_halt, [200, { "content-type" => "application/json" }, [JSON.generate(data)]]
    end
  end
end
