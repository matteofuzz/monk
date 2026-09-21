module Monk
  module Live
    # Who may subscribe to which topic (ADR 0009): deny by default. Rules
    # are matched in declaration order and the first match decides, like
    # routes, so a specific rule can sit above a general one. A topic no
    # rule matches is denied, and so is an anonymous subject (nil) unless
    # the matching rule says `anonymous: true`: a block like
    # `topic == "contacts:#{subject}"` would otherwise let a nil subject
    # in through "contacts:". A block that raises fails closed.
    module Policy
      Rule = Data.define(:pattern, :anonymous, :check) do
        def matches?(topic)
          if pattern.end_with?("*")
            topic.start_with?(pattern.chomp("*"))
          else
            topic == pattern
          end
        end
      end

      def self.build_rule(pattern, anonymous, block)
        unless pattern.is_a?(String) && !pattern.strip.empty? && valid_wildcard?(pattern)
          raise ArgumentError,
            "pattern must be a topic or a topic prefix ending in a single *, got #{pattern.inspect}"
        end
        raise ArgumentError, "authorize needs a block: { |subject, topic| ... }" unless block

        Rule.new(pattern: pattern.dup.freeze, anonymous: anonymous, check: shareable(block))
      end

      def self.allowed?(rules, subject, topic)
        rule = rules.find { |candidate| candidate.matches?(topic) }
        return false unless rule
        return false if subject.nil? && !rule.anonymous

        rule.check.call(subject, topic) ? true : false
      rescue StandardError
        false
      end

      def self.valid_wildcard?(pattern)
        pattern.count("*").zero? || (pattern.count("*") == 1 && pattern.end_with?("*"))
      end
      private_class_method :valid_wildcard?

      # Same constraint, same message shape, as Server#run's block.
      def self.shareable(block)
        Ractor.make_shareable(block)
      rescue ArgumentError, Ractor::IsolationError => e
        raise Monk::UnshareableBlockError,
          "Monk::Live.authorize block is not Ractor-shareable: #{e.message} " \
          "(build it where self is shareable, e.g. at class-body scope, not inline in a script's " \
          "top-level block)"
      end
      private_class_method :shareable
    end
  end
end
