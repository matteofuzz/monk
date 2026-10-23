module Monk
  module Live
    # Who may subscribe to which topic (ADR 0009): deny by default. Rules
    # are matched in declaration order and the first match decides, like
    # routes, so a specific rule can sit above a general one. A topic no
    # rule matches is denied, and so is an anonymous subject (nil) unless
    # the matching rule says `anonymous: true`: a block like
    # `topic == "contacts:#{subject}"` would otherwise let a nil subject
    # in through "contacts:". A block that raises fails closed.
    #
    # A rule with db_pool: runs its block in that Monk::Persistence::Pg
    # pool (docs/history/plan-pg-pool.md), not in the socket's own Ractor,
    # so a rule that queries the database doesn't open a connection per
    # open page. The block crosses to the pool as it is: rules are
    # shareable procs already. If the pool itself fails (not started in
    # this process, timed out, full), the rule denies and the reason is
    # logged.
    module Policy
      Rule = Data.define(:pattern, :anonymous, :check, :db_pool) do
        def matches?(topic)
          if pattern.end_with?("*")
            topic.start_with?(pattern.chomp("*"))
          else
            topic == pattern
          end
        end
      end

      def self.build_rule(pattern, anonymous, block, db_pool = nil)
        unless pattern.is_a?(String) && !pattern.strip.empty? && valid_wildcard?(pattern)
          raise ArgumentError,
            "pattern must be a topic or a topic prefix ending in a single *, got #{pattern.inspect}"
        end
        raise ArgumentError, "authorize needs a block: { |subject, topic| ... }" unless block
        unless db_pool.nil? || db_pool.is_a?(Symbol)
          raise ArgumentError, "db_pool must be a pool name (a Symbol), got #{db_pool.inspect}"
        end

        Rule.new(pattern: pattern.dup.freeze, anonymous: anonymous, check: shareable(block), db_pool: db_pool)
      end

      def self.allowed?(rules, subject, topic)
        rule = rules.find { |candidate| candidate.matches?(topic) }
        return false unless rule
        return false if subject.nil? && !rule.anonymous

        run(rule, subject, topic) ? true : false
      rescue Monk::PersistenceTimeoutError, Monk::PoolFullError, Monk::PoolNotStartedError, Monk::UnknownPoolError,
             Monk::PoolWorkerDiedError, Monk::PoolStoppedError => e
        log_pool_failure(rule, topic, e)
        false
      rescue StandardError
        false
      end

      # What a pooled rule runs in the pool's worker.
      def self.check(block, subject, topic) = block.call(subject, topic)

      def self.run(rule, subject, topic)
        return rule.check.call(subject, topic) unless rule.db_pool

        Monk::Persistence::Pg.pool(rule.db_pool).call(Policy, :check, rule.check, subject, topic)
      end
      private_class_method :run

      def self.log_pool_failure(rule, topic, error)
        Monk::Log.error(
          "Monk::Live: denied #{topic} (rule #{rule.pattern}): its pool #{rule.db_pool.inspect} failed: " \
          "#{error.class}: #{error.message}",
        )
      rescue StandardError
        nil
      end
      private_class_method :log_pool_failure

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
