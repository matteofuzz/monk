require_relative "test_helper"
require "json"
require "timeout"
require "socket"
require "monk/websocket"
require "monk/live"

class LiveSessionTest < Minitest::Test
  include WebSocketTestHelpers

  OWN_CONTACTS = proc { |subject, topic| topic == "contacts:#{subject}" }
  ALLOW = proc { |_subject, _topic| true }
  RAISES = proc { |_subject, _topic| raise "boom" }

  # A connection stand-in: Session only needs #read, #write and #subject.
  class FakeConnection
    attr_reader :subject, :outbox, :closed_with

    def initialize(subject)
      @subject = subject
      @inbox = Queue.new
      @outbox = Queue.new
    end

    def read = @inbox.pop

    def write(payload, **)
      raise EncodingError, "simulated write failure" if @fail_writes && payload.include?('"seq"')

      @outbox << payload
    end

    def fail_relayed_writes! = @fail_writes = true

    def close(code:, reason:)
      @closed_with = [code, reason]
      @inbox << nil # what a real Connection#read reports after a close
    end

    def send_message(message) = @inbox << (message.is_a?(String) ? message : JSON.generate(message))
    def hang_up = @inbox << nil
  end

  def setup
    @registry = Monk::WebSocket::Registry.new
    @publisher = Monk::Live::Publisher.new(@registry)
    @sessions = []
  end

  def teardown
    super # WebSocketTestHelpers: stops the integration test's server thread
    @sessions.each do |connection, thread|
      connection.hang_up
      thread.kill
    end
    Monk::Live.reset!
  end

  def test_an_allowed_subscribe_registers_the_topic_and_acks_it
    Monk::Live.authorize("contacts:*", &OWN_CONTACTS)
    connection = start_session("7")

    connection.send_message(op: "subscribe", topics: ["contacts:7"])

    assert_equal({ "op" => "subscribed", "topics" => ["contacts:7"], "denied" => [] }, next_json(connection))
    assert_equal 1, @registry.count(:"contacts:7")
  end

  def test_a_denied_topic_is_never_registered_and_is_listed_as_denied
    Monk::Live.authorize("contacts:*", &OWN_CONTACTS)
    connection = start_session("7")

    connection.send_message(op: "subscribe", topics: ["contacts:8", "contacts:7"])

    assert_equal({ "op" => "subscribed", "topics" => ["contacts:7"], "denied" => ["contacts:8"] },
      next_json(connection),)
    assert_equal 0, @registry.count(:"contacts:8")
  end

  def test_nothing_is_allowed_when_no_rule_is_declared
    connection = start_session("7")

    connection.send_message(op: "subscribe", topics: ["contacts:7"])

    assert_equal ["contacts:7"], next_json(connection)["denied"]
    assert_equal 0, @registry.count(:"contacts:7")
  end

  def test_an_anonymous_connection_cannot_subscribe_unless_the_rule_says_anonymous
    Monk::Live.authorize("contacts:*", &OWN_CONTACTS)
    Monk::Live.authorize("public:*", anonymous: true, &ALLOW)
    connection = start_session(nil)

    connection.send_message(op: "subscribe", topics: ["contacts:", "public:news"])

    reply = next_json(connection)
    assert_equal ["public:news"], reply["topics"]
    assert_equal ["contacts:"], reply["denied"]
  end

  def test_a_policy_block_that_raises_denies_and_keeps_the_connection_alive
    Monk::Live.authorize("x:*", &RAISES)
    connection = start_session("7")

    connection.send_message(op: "subscribe", topics: ["x:1"])
    assert_equal ["x:1"], next_json(connection)["denied"]

    connection.send_message(op: "unsubscribe", topics: ["x:1"])
    assert_equal "unsubscribed", next_json(connection)["op"]
  end

  def test_malformed_topics_are_denied_before_the_policy_sees_them
    Monk::Live.authorize("*", &ALLOW)
    connection = start_session("7")
    bad = ["", "contacts:*", "a b", "a\0b", "x" * 201, "caffè", "\n"]

    connection.send_message(op: "subscribe", topics: bad)

    reply = next_json(connection)
    assert_equal [], reply["topics"]
    assert_equal bad, reply["denied"]
  end

  def test_the_per_connection_topic_cap_denies_the_overflow
    Monk::Live.authorize("t:*", &ALLOW)
    Monk::Live.configure(registry: @registry, max_topics: 2)
    connection = start_session("7")

    connection.send_message(op: "subscribe", topics: %w[t:1 t:2 t:3])

    reply = next_json(connection)
    assert_equal %w[t:1 t:2], reply["topics"]
    assert_equal ["t:3"], reply["denied"]
  end

  def test_subscribing_twice_is_idempotent
    Monk::Live.authorize("t:*", &ALLOW)
    connection = start_session("7")

    2.times do
      connection.send_message(op: "subscribe", topics: ["t:1"])
      assert_equal ["t:1"], next_json(connection)["topics"]
    end
    assert_equal 1, @registry.count(:"t:1")
  end

  def test_unsubscribe_deregisters_and_stops_delivery
    Monk::Live.authorize("t:*", &ALLOW)
    connection = start_session("7")
    connection.send_message(op: "subscribe", topics: %w[t:1 t:2])
    next_json(connection)

    connection.send_message(op: "unsubscribe", topics: %w[t:1 t:never])

    assert_equal({ "op" => "unsubscribed", "topics" => ["t:1"] }, next_json(connection))
    assert_equal 0, @registry.count(:"t:1")
    @publisher.remove("t:1", to: "#gone")
    @publisher.remove("t:2", to: "#kept")
    assert_equal "#kept", next_json(connection)["target"]
  end

  def test_published_envelopes_are_relayed_with_a_per_connection_seq
    Monk::Live.authorize("t:*", &ALLOW)
    connection = start_session("7")
    connection.send_message(op: "subscribe", topics: ["t:1"])
    next_json(connection)

    @publisher.remove("t:1", to: "#a")
    @publisher.remove("t:1", to: "#b")

    first = next_json(connection)
    second = next_json(connection)
    assert_equal({ "seq" => 1, "op" => "patch", "target" => "#a", "mode" => "remove" }, first)
    assert_equal [2, "#b"], second.values_at("seq", "target")
  end

  def test_each_connection_counts_its_own_seq
    Monk::Live.authorize("t:*", &ALLOW)
    early = start_session("1")
    early.send_message(op: "subscribe", topics: ["t:1"])
    next_json(early)
    @publisher.remove("t:1", to: "#first")
    next_json(early)

    late = start_session("2")
    late.send_message(op: "subscribe", topics: ["t:1"])
    next_json(late)
    @publisher.remove("t:1", to: "#second")

    assert_equal 1, next_json(late)["seq"]
    assert_equal 2, next_json(early)["seq"]
  end

  def test_one_connection_can_hold_several_topics
    Monk::Live.authorize("t:*", &ALLOW)
    connection = start_session("7")
    connection.send_message(op: "subscribe", topics: %w[t:1 t:2])
    next_json(connection)

    @publisher.remove("t:1", to: "#a")
    @publisher.remove("t:2", to: "#b")

    assert_equal %w[#a #b], [next_json(connection)["target"], next_json(connection)["target"]]
  end

  def test_bad_messages_get_an_error_reply_and_do_not_close_the_connection
    Monk::Live.authorize("t:*", &ALLOW)
    connection = start_session("7")
    bad_messages = [
      "not json", "123", "[]", '{"op":"explode"}', '{"op":"subscribe"}', '{"op":"subscribe","topics":"t:1"}',
      '{"op":"subscribe","topics":[1]}', JSON.generate(op: "subscribe", topics: Array.new(101) { |i| "t:#{i}" }),
    ]

    bad_messages.each do |message|
      connection.send_message(message)
      assert_equal({ "op" => "error", "reason" => "bad_message" }, next_json(connection), message[0, 40])
    end

    connection.send_message(op: "subscribe", topics: ["t:1"])
    assert_equal ["t:1"], next_json(connection)["topics"]
  end

  def test_a_failing_relay_closes_the_connection_instead_of_leaving_it_silently_stale
    Monk::Live.authorize("t:*", &ALLOW)
    connection, thread = start_session("7", with_thread: true)
    connection.send_message(op: "subscribe", topics: ["t:1"])
    next_json(connection)
    connection.fail_relayed_writes!

    silence_stderr { @publisher.remove("t:1", to: "#a") }
    thread.join(3)

    assert_equal [1011, "relay failed"], connection.closed_with
    assert_equal 0, @registry.count(:"t:1"), "the session did not clean up after closing"
  end

  def test_the_real_handler_relays_non_ascii_fragments_over_a_socket
    Monk::Live.configure(registry: @registry)
    Monk::Live.authorize("public:*", anonymous: true, &ALLOW)
    server = start_server(&Monk::Live::HANDLER)
    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)
    socket.write(Monk::WebSocket::Frame.encode(JSON.generate(op: "subscribe", topics: ["public:news"]), opcode: 0x1))
    Timeout.timeout(3) { read_frame(socket) }

    @publisher.remove("public:news", to: "#caff\u00e8-\u2603")

    assert_equal "#caff\u00e8-\u2603", JSON.parse(Timeout.timeout(3) { read_frame(socket) })["target"]
  ensure
    socket&.close
  end

  def test_hanging_up_removes_every_registration
    Monk::Live.authorize("t:*", &ALLOW)
    connection, thread = start_session("7", with_thread: true)
    connection.send_message(op: "subscribe", topics: %w[t:1 t:2])
    next_json(connection)

    connection.hang_up
    thread.join(2)

    assert_equal [0, 0], [@registry.count(:"t:1"), @registry.count(:"t:2")]
  end

  def test_a_crashing_read_still_removes_every_registration
    Monk::Live.authorize("t:*", &ALLOW)
    connection = start_session("7")
    connection.send_message(op: "subscribe", topics: ["t:1"])
    next_json(connection)
    session_thread = @sessions.last.last

    session_thread.report_on_exception = false
    session_thread.raise("simulated crash")
    assert_raises(RuntimeError) { session_thread.join(2) }

    assert_equal 0, @registry.count(:"t:1")
  end

  def test_the_real_handler_serves_a_subscribe_and_a_publish_over_a_socket_and_cleans_up
    Monk::Live.configure(registry: @registry)
    Monk::Live.authorize("public:*", anonymous: true, &ALLOW)
    server = start_server(&Monk::Live::HANDLER)
    socket = TCPSocket.new("127.0.0.1", server.port)
    handshake!(socket)

    socket.write(Monk::WebSocket::Frame.encode(JSON.generate(op: "subscribe", topics: ["public:news"]), opcode: 0x1))
    assert_equal ["public:news"], JSON.parse(Timeout.timeout(3) { read_frame(socket) })["topics"]
    @publisher.remove("public:news", to: "#x")
    assert_equal [1, "#x"], JSON.parse(Timeout.timeout(3) { read_frame(socket) }).values_at("seq", "target")

    socket.close
    wait_until(timeout: 3) { @registry.count(:"public:news").zero? }
  ensure
    socket&.close
  end

  def test_the_handler_needs_a_configured_registry
    connection = FakeConnection.new("7")

    assert_raises(Monk::Live::NotConfiguredError) { Monk::Live::HANDLER.call(connection) }
  end

  private

  # Runs a Session on a background thread against a FakeConnection, wired
  # to this test's registry and whatever rules the test declared.
  def start_session(subject, with_thread: false)
    connection = FakeConnection.new(subject)
    thread = Thread.new do
      Monk::Live::Session.new(
        connection, registry: @registry, rules: Monk::Live.rules, max_topics: Monk::Live.max_topics,
      ).run
    end
    @sessions << [connection, thread]
    with_thread ? [connection, thread] : connection
  end

  # The relay thread reports the failure it is about to close over on stderr.
  def silence_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    sleep 0.3 # let the relay thread run
  ensure
    $stderr = original
  end

  def next_json(connection)
    JSON.parse(Timeout.timeout(3) { connection.outbox.pop })
  end
end
