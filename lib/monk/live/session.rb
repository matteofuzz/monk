require "json"

module Monk
  module Live
    # One WebSocket connection's live state, running inside its own
    # connection Ractor: the subscribe/unsubscribe protocol, the topic
    # authorization check, and the relay that stamps each published
    # envelope with this connection's own `seq` before writing it.
    #
    # Client -> server: {"op":"subscribe"|"unsubscribe","topics":[...]}.
    # Replies: subscribed (+ denied), unsubscribed, or error/bad_message.
    # A denial never says why or whether the topic exists.
    #
    # `connection` is anything with #read, #write and #subject.
    class Session
      # No `*`, no whitespace or NUL, ASCII only: a client can't smuggle a
      # glob or a delimiter into a topic, and only a topic that passed this
      # and the policy is ever turned into a Symbol.
      TOPIC_FORMAT = %r{\A[\w:.\-/@]{1,200}\z}
      MAX_TOPICS_PER_MESSAGE = 100

      def initialize(connection, registry:, rules:, max_topics:)
        @connection = connection
        @registry = registry
        @rules = rules
        @max_topics = max_topics
        @topics = {} # String topic => the Symbol it is registered under
      end

      def run
        @port = Ractor::Port.new
        @relay = Thread.new { relay }
        while (raw = @connection.read)
          dispatch(raw)
        end
      ensure
        cleanup
      end

      private

      def dispatch(raw)
        message = JSON.parse(raw, max_nesting: 5)
        topics = message.is_a?(Hash) ? message["topics"] : nil
        return reply(op: "error", reason: "bad_message") unless valid_topics?(topics)

        case message["op"]
        when "subscribe" then subscribe(topics)
        when "unsubscribe" then unsubscribe(topics)
        else reply(op: "error", reason: "bad_message")
        end
      rescue JSON::ParserError
        reply(op: "error", reason: "bad_message")
      end

      def valid_topics?(topics)
        topics.is_a?(Array) && topics.size <= MAX_TOPICS_PER_MESSAGE &&
          topics.all? { |topic| topic.is_a?(String) && topic.valid_encoding? }
      end

      def subscribe(topics)
        allowed, denied = topics.partition { |topic| try_subscribe?(topic) }
        reply(op: "subscribed", topics: allowed, denied: denied)
      end

      def try_subscribe?(topic)
        return true if @topics.key?(topic)
        return false unless permitted?(topic) && @topics.size < @max_topics

        key = topic.to_sym
        @registry.register(key, @port)
        @topics[topic] = key
        true
      end

      def permitted?(topic)
        TOPIC_FORMAT.match?(topic) && Policy.allowed?(@rules, @connection.subject, topic)
      end

      def unsubscribe(topics)
        removed = topics.select { |topic| @topics.key?(topic) }
        removed.each { |topic| @registry.unregister(@topics.delete(topic), @port) }
        reply(op: "unsubscribed", topics: removed)
      end

      def reply(message)
        @connection.write(JSON.generate(message))
      end

      # Runs on its own thread: each published envelope gets the next
      # per-connection seq spliced in after its opening `{`. The
      # publisher's frozen string is shared by every subscriber (ADR
      # 0010), so the stamp has to be a per-connection copy made here.
      def relay
        seq = 0
        loop do
          payload = @port.receive
          seq += 1
          @connection.write(payload.start_with?("{") ? "{\"seq\":#{seq},#{payload.byteslice(1..)}" : payload)
        end
      rescue Ractor::ClosedError, IOError, SystemCallError
        # cleanup closed the port, or the socket went away first.
      end

      # On every exit path -- clean hang-up, close handshake, a crashed
      # read -- so a connection never leaves a stale registry entry.
      def cleanup
        @relay&.kill
        @topics.each_value { |key| @registry.unregister(key, @port) }
        @topics.clear
        @port&.close
      end
    end
  end
end
