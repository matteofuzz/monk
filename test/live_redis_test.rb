require_relative "test_helper"
require "json"
require "socket"
require_relative "live_multiprocess_helpers"

# Phase 7: the publisher only speaks Registry's interface, so a RedisFanout
# makes it cross-process. These tests prove it end to end: a fragment rendered
# in this process reaches a real WebSocket client connected to a different
# process, with `seq` stamped there, per connection.
class LiveRedisTest < Minitest::Test
  include WebSocketTestHelpers
  include LiveMultiprocessHelpers

  ROW = %(<li id="c-<%= locals[:id] %>"><%= locals[:text] %></li>).freeze

  def setup
    skip_unless_redis_available
    start_ws_process
    build_publisher
    @sockets = []
  end

  def teardown
    super
    @sockets&.each { |socket| socket.close unless socket.closed? }
    stop_ws_process
    Monk::Live.reset!
  end

  def test_a_patch_rendered_here_reaches_a_client_on_another_process_with_its_seq
    with_frozen_views({ "row.erb" => ROW }) do
      topic = unique_topic
      client = connect_and_subscribe(topic)

      @publisher.patch(topic, to: "#c-1", partial: "row", id: 1, text: "Ada")

      assert_equal(
        { "seq" => 1, "op" => "patch", "target" => "#c-1", "mode" => "morph", "html" => %(<li id="c-1">Ada</li>) },
        next_frame(client),
      )
    end
  end

  def test_seq_is_counted_per_connection_at_the_edge_not_by_the_publisher
    topic = unique_topic
    early = connect_and_subscribe(topic)
    2.times { @publisher.remove(topic, to: "#x") }
    assert_equal [1, 2], [next_frame(early)["seq"], next_frame(early)["seq"]]

    late = connect_and_subscribe(topic)
    @publisher.remove(topic, to: "#x")

    assert_equal 1, next_frame(late)["seq"], "a connection that joined late must start at 1"
    assert_equal 3, next_frame(early)["seq"]
  end

  def test_a_topic_only_reaches_its_own_subscribers_across_the_hop
    mine = unique_topic
    other = unique_topic
    on_mine = connect_and_subscribe(mine)
    on_other = connect_and_subscribe(other)

    @publisher.remove(other, to: "#for-other")
    @publisher.remove(mine, to: "#for-mine")

    assert_equal "#for-mine", next_frame(on_mine)["target"]
    assert_equal "#for-other", next_frame(on_other)["target"]
  end

  def test_a_large_multiline_unicode_fragment_survives_the_redis_hop_intact
    html = ("<p title=\"a&b\">caffè ☃ \"quoted\"\n\ttabbed \\ backslash</p>\n" * 2_500)
    with_frozen_views({ "big.erb" => "<%= raw(locals[:html]) %>" }) do
      topic = unique_topic
      client = connect_and_subscribe(topic)

      @publisher.patch(topic, to: "#big", partial: "big", html: html)

      received = next_frame(client, timeout: 10)["html"]
      assert_equal html.bytesize, received.bytesize
      assert_equal html, received
    end
  end

  def test_publishing_from_a_non_main_ractor_reaches_the_other_process
    with_frozen_views({ "row.erb" => ROW }) do
      topic = unique_topic
      client = connect_and_subscribe(topic)
      Monk::Live.configure(registry: @fanout)

      Ractor.new(topic) { |t| Monk::Live.patch(t, to: "#c-9", partial: "row", id: 9, text: "from a Ractor") }.value

      assert_equal %(<li id="c-9">from a Ractor</li>), next_frame(client)["html"]
    end
  end

  def test_a_subscriber_in_the_publishing_process_gets_it_once_and_the_remote_one_too
    topic = unique_topic
    remote = connect_and_subscribe(topic)
    local = Ractor::Port.new
    @registry.register(topic.to_sym, local)

    @publisher.remove(topic, to: "#first")
    @publisher.remove(topic, to: "#second")

    assert_equal %w[#first #second], [next_frame(remote)["target"], next_frame(remote)["target"]]
    assert_equal(%w[#first #second], 2.times.map { JSON.parse(Timeout.timeout(3) { local.receive })["target"] })
  ensure
    local&.close
  end

  private

  def connect_and_subscribe(topic)
    socket = TCPSocket.new("127.0.0.1", @ws_port)
    @sockets << socket
    handshake!(socket)
    socket.write(Monk::WebSocket::Frame.encode(JSON.generate(op: "subscribe", topics: [topic]), opcode: 0x1))
    reply = next_frame(socket)
    raise "subscribe refused: #{reply}" unless reply["topics"] == [topic]

    socket
  end

  def next_frame(socket, timeout: 5)
    JSON.parse(Timeout.timeout(timeout) { read_frame(socket) })
  end
end
