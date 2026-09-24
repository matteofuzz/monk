require_relative "test_helper"
require "json"
require "socket"
require_relative "live_multiprocess_helpers_pg"

# Phase 4 (docs/history/plan-live-pg-fanout.md): the publisher only speaks
# Registry's interface, so a PgFanout makes it cross-process the same way
# a RedisFanout does (live_redis_test.rb). These tests prove it end to
# end, through Postgres only: a fragment rendered in this process reaches
# a real WebSocket client connected to a different process, with `seq`
# stamped there, per connection.
class LivePgTest < Minitest::Test
  include WebSocketTestHelpers
  include LiveMultiprocessHelpersPg

  ROW = %(<li id="c-<%= locals[:id] %>"><%= locals[:text] %></li>).freeze

  def setup
    skip_unless_postgres_available
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

  # RedisFanout has no payload cap, so live_redis_test.rb's equivalent
  # (test_a_large_multiline_unicode_fragment_survives_the_redis_hop_intact)
  # uses a ~130KB fragment; that would trip PgFanout's own
  # MAX_NOTIFY_PAYLOAD_BYTES guard outright, a real difference between the
  # two transports (docs/design/live-pg-fanout.md's "Where this is worse
  # than Redis"), not something to work around here. Scaled down to stay
  # comfortably under the cap while still exercising the same byte-fidelity
  # question: does a multi-line fragment with quotes, backslashes, tabs and
  # multi-byte Unicode survive the length-prefixed envelope and the
  # Postgres hop exactly, not just typical ASCII HTML.
  def test_a_multiline_unicode_fragment_survives_the_postgres_hop_intact
    html = ("<p title=\"a&b\">caffè ☃ \"quoted\"\n\ttabbed \\ backslash</p>\n" * 40)
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
