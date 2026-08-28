require "json"

module Monk
  class Context
    attr_reader :params
    attr_accessor :status

    def initialize(params, status: 200)
      @params = params
      @status = status
    end

    def halt(status, body = "")
      throw :monk_halt, [status, {}, [body]]
    end

    def json(data)
      throw :monk_halt, [status, { "content-type" => "application/json" }, [JSON.generate(data)]]
    end
  end
end
