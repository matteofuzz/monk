module Monk
  module Live
    class NotFrozenError < StandardError
    end

    class NotConfiguredError < StandardError
    end
  end
end
