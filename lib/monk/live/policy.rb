module Monk
  module Live
    # Who may subscribe to which topic (ADR 0009): deny by default. Rules
    # are matched in declaration order and the first match decides, like
    # routes, so a specific rule can sit above a general one. A topic no
    # rule matches is denied, and so is an anonymous subject (nil) unless
    # the matching rule says `anonymous: true`: a block like
    # `topic == "contacts:#{subject}"` would otherwise let a nil subject
    # in through "contacts:". A block that raises fails closed, and the
    # reason is logged.
    #
    # A rule with db_pool: runs its block in that Monk::Persistence::Pg pool,
    # not in the socket's own Ractor, so a rule that queries the database
    # doesn't open a connection per open page. The block crosses to the pool
    # as it is: rules are shareable procs already. If the pool itself fails
    # (not started in this process, timed out, full), the rule denies and the
    # reason is logged.
    #
    # A rule with batch: true decides a subscribe message's topics in one
    # call: its block gets every topic of the message that this rule
    # matches first (at most Session::MAX_TOPICS_PER_MESSAGE), and returns
    # the allowed ones, an Array or a Set; nil or false allows none. With
    # db_pool:, that's one pool call per message, not one per topic. A
    # returned topic that wasn't asked for is ignored; any other result
    # denies them all and is logged, so `true` never means "all". A
    # single-topic rule that returns a collection denies too: it is a batch
    # block missing batch: true, and an Array is truthy even when empty.
    module Policy
      Rule = Data.define(:pattern, :anonymous, :check, :db_pool, :batch) do
        def matches?(topic)
          if pattern.end_with?("*")
            topic.start_with?(pattern.chomp("*"))
          else
            topic == pattern
          end
        end
      end

      POOL_ERRORS = [
        Monk::PersistenceTimeoutError, Monk::PoolFullError, Monk::PoolNotStartedError, Monk::UnknownPoolError,
        Monk::PoolWorkerDiedError, Monk::PoolStoppedError,
      ].freeze

      def self.build_rule(pattern, anonymous, block, db_pool: nil, batch: false)
        unless pattern.is_a?(String) && !pattern.strip.empty? && valid_wildcard?(pattern)
          raise ArgumentError,
            "pattern must be a topic or a topic prefix ending in a single *, got #{pattern.inspect}"
        end
        raise ArgumentError, "authorize needs a block: { |subject, topic| ... }" unless block
        unless db_pool.nil? || db_pool.is_a?(Symbol)
          raise ArgumentError, "db_pool must be a pool name (a Symbol), got #{db_pool.inspect}"
        end
        raise ArgumentError, "batch must be true or false, got #{batch.inspect}" unless [true, false].include?(batch)

        Rule.new(pattern: pattern.dup.freeze, anonymous: anonymous, check: shareable(block), db_pool: db_pool,
          batch: batch,)
      end

      def self.allowed?(rules, subject, topic) = allowed_topics(rules, subject, [topic]).include?(topic)

      # The topics of one subscribe message that may be subscribed, as a
      # Set. Each distinct topic goes to the first rule it matches; a
      # single-topic rule is called per topic, a batch rule once with its
      # group. Topics are frozen first, so a block can't change one the
      # session goes on to register.
      def self.allowed_topics(rules, subject, topics)
        groups = {}.compare_by_identity
        topics.uniq.each do |topic|
          rule = rules.find { |candidate| candidate.matches?(topic) }
          (groups[rule] ||= []) << topic.freeze if rule
        end

        groups.each_with_object(Set.new) do |(rule, group), allowed|
          next if subject.nil? && !rule.anonymous

          if rule.batch
            allowed.merge(decide_many(rule, subject, group.freeze))
          else
            group.each { |topic| allowed << topic if decide(rule, subject, topic) }
          end
        end
      end

      # What a pooled rule runs in the pool's worker: one topic, or a
      # batch rule's group.
      def self.check(block, subject, topics) = block.call(subject, topics)

      def self.decide(rule, subject, topic)
        result = run(rule, subject, topic)
        if result.is_a?(Array) || result.is_a?(Set) || result.is_a?(Hash)
          log_denial(rule, topic,
            "its block returned #{result.class}: a rule that returns the allowed topics needs batch: true",)
          return false
        end
        result ? true : false
      rescue *POOL_ERRORS => e
        log_pool_failure(rule, topic, e)
        false
      rescue StandardError => e
        log_denial(rule, topic, "its block raised #{e.class}: #{e.message}")
        false
      end
      private_class_method :decide

      def self.decide_many(rule, subject, group)
        case (result = run(rule, subject, group))
        when nil, false then []
        when Array, Set then group & result.to_a
        else
          log_denial(rule, counted(group),
            "its block returned #{result.class}, not the allowed topics (an Array or a Set)",)
          []
        end
      rescue *POOL_ERRORS => e
        log_pool_failure(rule, counted(group), e)
        []
      rescue StandardError => e
        log_denial(rule, counted(group), "its block raised #{e.class}: #{e.message}")
        []
      end
      private_class_method :decide_many

      def self.counted(group) = group.size == 1 ? "1 topic" : "#{group.size} topics"
      private_class_method :counted

      def self.run(rule, subject, topics)
        return rule.check.call(subject, topics) unless rule.db_pool

        Monk::Persistence::Pg.pool(rule.db_pool).call(Policy, :check, rule.check, subject, topics)
      end
      private_class_method :run

      def self.log_pool_failure(rule, what, error)
        log_denial(rule, what, "its pool #{rule.db_pool.inspect} failed: #{error.class}: #{error.message}")
      end
      private_class_method :log_pool_failure

      def self.log_denial(rule, what, reason)
        Monk::Log.error("Monk::Live: denied #{what} (rule #{rule.pattern}): #{reason}")
      rescue StandardError
        nil
      end
      private_class_method :log_denial

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
