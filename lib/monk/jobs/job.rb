module Monk
  # The class an app's jobs inherit from:
  #
  #   class SendReceipt < Monk::Job
  #     queue "mailers"   # optional; "default" otherwise
  #     priority 10       # optional; lower runs sooner, 0 otherwise
  #     max_attempts 3    # optional; 5 otherwise
  #
  #     def self.perform(order_id)
  #       ...
  #     end
  #   end
  #
  # A class, not a block: a Class is always Ractor-shareable, so #perform
  # is callable from every worker Ractor without the make_shareable rules
  # a Proc has to meet (docs/design/ractor.md). Settings are inherited, so
  # an app can put shared ones on its own base class.
  class Job
    DEFAULT_QUEUE = "default".freeze
    DEFAULT_PRIORITY = 0
    DEFAULT_MAX_ATTEMPTS = 5

    # monk_jobs.priority and max_attempts are SMALLINT columns.
    PRIORITY_RANGE = -32_768..32_767
    MAX_ATTEMPTS_RANGE = 1..32_767

    class << self
      def inherited(subclass)
        super
        Monk::Jobs.record(subclass)
      end

      def queue(name = nil)
        return @queue || inherited_setting(:queue, DEFAULT_QUEUE) if name.nil?

        unless name.is_a?(String) && !name.empty?
          raise ArgumentError, "#{self.name || "a job"}'s queue must be a non-empty String, got #{name.inspect}"
        end

        # Frozen, so a worker Ractor can read it back off the class.
        @queue = name.dup.freeze
      end

      def priority(value = nil)
        return @priority || inherited_setting(:priority, DEFAULT_PRIORITY) if value.nil?

        @priority = checked_integer(:priority, value, PRIORITY_RANGE)
      end

      def max_attempts(value = nil)
        return @max_attempts || inherited_setting(:max_attempts, DEFAULT_MAX_ATTEMPTS) if value.nil?

        @max_attempts = checked_integer(:max_attempts, value, MAX_ATTEMPTS_RANGE)
      end

      def perform(*)
        raise NotImplementedError, "#{name || "this job"} must define self.perform"
      end

      private

      def inherited_setting(setting, default)
        equal?(Monk::Job) ? default : superclass.public_send(setting)
      end

      def checked_integer(setting, value, range)
        return value if value.is_a?(Integer) && range.cover?(value)

        raise ArgumentError, "#{name || "a job"}'s #{setting} must be an Integer in #{range}, got #{value.inspect}"
      end
    end
  end
end
