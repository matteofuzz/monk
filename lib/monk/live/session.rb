require "json"

module Monk
  module Live
    # Seconds between the client's pings while its page is visible:
    # protocol.js's HEARTBEAT, which a test keeps equal. What Away means
    # follows from it (ADR 0019), so the two are changed together.
    HEARTBEAT = 25

    # One WebSocket connection's live state, running inside its own
    # connection Ractor: the subscribe/unsubscribe protocol, the topic
    # authorization check, and the relay that stamps each published
    # envelope with this connection's own `seq` before writing it.
    #
    # Client -> server: {"op":"subscribe"|"unsubscribe","topics":[...]}.
    # Replies: subscribed (+ denied), unsubscribed, or error/bad_message.
    # And {"op":"ping"} -> {"op":"pong"}: the client's heartbeat, since
    # browser JS can't see WebSocket pings. {"op":"hidden"}, with no
    # reply: the client's page was just hidden.
    # A denial never says why or whether the topic exists.
    #
    # `connection` is anything with #read, #write and #subject. One that
    # #tracks_presence? (Server.new(presence:)) is also told, through
    # #visible=, whether its page is visible: while its client has pinged
    # within visible_for, 2 x HEARTBEAT (ADR 0019). The client pings only
    # while its page is visible, and at once on open, so this is Away. It
    # also says when its page is hidden, so Away shows at once; the
    # silence covers a page frozen before it could say so, checked on the
    # connection's heartbeat (Connection#on_heartbeat), once per server
    # ping: no thread of its own, which at 15K sockets cost more than
    # everything else presence does (docs/plan-live-networks-presence.md).
    class Session
      # No `*`, no whitespace or NUL, ASCII only: a client can't smuggle a
      # glob or a delimiter into a topic, and only a topic that passed this
      # and the policy is ever turned into a Symbol.
      TOPIC_FORMAT = %r{\A[\w:.\-/@]{1,200}\z}
      MAX_TOPICS_PER_MESSAGE = 100

      VISIBLE_FOR = 2 * HEARTBEAT

      def initialize(connection, registry:, rules:, max_topics:, visible_for: VISIBLE_FOR)
        @connection = connection
        @registry = registry
        @rules = rules
        @max_topics = max_topics
        @topics = {} # String topic => the Symbol it is registered under
        @visible_for = visible_for
        @presence = connection.respond_to?(:tracks_presence?) && connection.tracks_presence?
        @visibility = Mutex.new
      end

      def run
        @port = Ractor::Port.new
        @relay = Thread.new { relay }
        @connection.on_heartbeat { check_visibility } if @presence
        while (raw = @connection.read)
          dispatch(raw)
        end
      ensure
        cleanup
      end

      private

      def dispatch(raw)
        message = JSON.parse(raw, max_nesting: 5)
        return pinged if message.is_a?(Hash) && message["op"] == "ping"
        return hidden if message.is_a?(Hash) && message["op"] == "hidden"

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

      # The new topics go to the registry in one ask, not one each: at a
      # reconnect wave's rate, one ask per topic is most of the registry
      # Ractor's work (docs/plan-ws-connect-ceiling.md, item 5).
      def subscribe(topics)
        added = {}
        allowed, denied = topics.partition { |topic| try_subscribe?(topic, added) }
        unless added.empty?
          @registry.register_many(added.values, @port)
          @topics.merge!(added)
        end
        reply(op: "subscribed", topics: allowed, denied: denied)
      end

      def try_subscribe?(topic, added)
        return true if @topics.key?(topic) || added.key?(topic)
        return false unless permitted?(topic) && @topics.size + added.size < @max_topics

        added[topic] = topic.to_sym
        true
      end

      def permitted?(topic)
        TOPIC_FORMAT.match?(topic) && Policy.allowed?(@rules, @connection.subject, topic)
      end

      def unsubscribe(topics)
        removed = topics.select { |topic| @topics.key?(topic) }
        keys = removed.filter_map { |topic| @topics.delete(topic) }
        @registry.unregister_many(keys, @port) unless keys.empty?
        reply(op: "unsubscribed", topics: removed)
      end

      def reply(message)
        @connection.write(JSON.generate(message))
      end

      def pinged
        if @presence
          @visibility.synchronize do
            @last_ping = Monk::WebSocket::Connection.monotonic
            @connection.visible = true
          end
        end
        reply(op: "pong")
      end

      def hidden
        return unless @presence

        @visibility.synchronize do
          @last_ping = nil
          @connection.visible = false
        end
      end

      # On the connection's heartbeat, once per server ping: the page turns
      # hidden once no ping has come for visible_for, so up to one ping
      # interval late.
      def check_visibility
        @visibility.synchronize do
          if @last_ping && Monk::WebSocket::Connection.monotonic - @last_ping >= @visible_for
            @last_ping = nil
            @connection.visible = false
          end
        end
      end

      # Runs on its own thread: each published envelope gets the next
      # per-connection seq spliced in after its opening `{`. The
      # publisher's frozen string is shared by every subscriber (ADR
      # 0010), so the stamp has to be a per-connection copy made here.
      def relay
        seq = 0
        loop do
          payload = @port.receive
          # Registry#close_all: broadcasts were missed, so the client must
          # reconnect and resync (ADR 0011). run's read loop ends, and
          # cleanup unregisters every topic.
          if payload.is_a?(Monk::WebSocket::CloseRequest)
            return @connection.close(code: payload.code, reason: payload.reason)
          end

          seq += 1
          @connection.write(payload.start_with?("{") ? "{\"seq\":#{seq},#{payload.byteslice(1..)}" : payload)
        end
      rescue Ractor::ClosedError, IOError, SystemCallError
        # cleanup closed the port, or the socket went away first.
      rescue StandardError => e
        # Anything else would leave a connected client silently receiving
        # nothing: a stale page nobody knows is stale. Closing makes the
        # client reconnect and resync (ADR 0011), which is the recovery.
        warn "monk-live: relay failed, closing connection: #{e.class}: #{e.message}"
        @connection.close(code: 1011, reason: "relay failed")
      end

      # On every exit path -- clean hang-up, close handshake, a crashed
      # read -- so a connection never leaves a stale registry entry.
      def cleanup
        @relay&.kill
        @registry.unregister_many(@topics.values, @port) unless @topics.empty?
        @topics.clear
        @port&.close
      end
    end
  end
end
