module Monk
  class StateRactor
    def initialize(initial_value)
      @ractor = Ractor.new(initial_value) do |value|
        loop do
          op, arg, reply_port = Ractor.receive
          case op
          when :value
            reply_port.send(value)
          when :update
            value = arg.call(value)
            reply_port.send(value)
          end
        end
      end
      freeze
    end

    def value
      ask(:value)
    end

    def update(&block)
      begin
        shareable_block = Ractor.make_shareable(block)
      rescue ArgumentError, Ractor::IsolationError => e
        raise UnshareableBlockError,
          "StateRactor#update block is not Ractor-shareable: #{e.message} " \
          "(build it where self is shareable, e.g. at app-definition time, not inline in a route handler)"
      end

      ask(:update, shareable_block)
    end

    private

    def ask(op, arg = nil)
      reply_port = Ractor::Port.new
      @ractor.send([op, arg, reply_port])
      reply_port.receive
    ensure
      reply_port&.close
    end
  end
end
