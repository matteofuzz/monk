module Monk
  module Jobs
    # A job's args are stored as JSON (monk_job_payloads.args) and handed
    # back to #perform in another process, so only values that come back
    # from that round trip unchanged are accepted: Strings, Integers,
    # finite Floats, true/false/nil, and Arrays and String-keyed Hashes of
    # those. Checked when a job is enqueued, so a bad argument fails in
    # the code that passed it rather than later, in a worker.
    module Args
      def self.check!(args)
        raise InvalidArgumentsError, "a job's args must be an Array, got #{args.class}" unless args.is_a?(Array)

        args.each_with_index { |value, i| check_value!(value, "args[#{i}]") }
        nil
      end

      def self.check_value!(value, path)
        case value
        when String, Integer, true, false, nil
          nil
        when Float
          raise InvalidArgumentsError, "#{path} is #{value}, which JSON can't represent" unless value.finite?
        when Array
          value.each_with_index { |item, i| check_value!(item, "#{path}[#{i}]") }
        when Hash
          value.each do |key, item|
            unless key.is_a?(String)
              raise InvalidArgumentsError,
                "#{path} has the key #{key.inspect} (a #{key.class}); JSON only has String keys, so " \
                "#perform would get back a different Hash -- use #{key.to_s.inspect}"
            end
            check_value!(item, "#{path}[#{key.inspect}]")
          end
        else
          raise InvalidArgumentsError,
            "#{path} is a #{value.class}, which doesn't survive a JSON round trip -- pass plain values " \
            "(e.g. an id rather than a record, an ISO 8601 String rather than a Time)"
        end
      end
      private_class_method :check_value!
    end
  end
end
