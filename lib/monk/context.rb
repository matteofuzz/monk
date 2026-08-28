module Monk
  class Context
    attr_reader :params

    def initialize(params)
      @params = params
    end
  end
end
