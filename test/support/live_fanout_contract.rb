require "json"
require "socket"

# Monk::Live across processes, end to end, whichever fanout carries it:
# the publisher only speaks Registry's interface, so a fragment rendered
# in this process reaches a real WebSocket client connected to a child WS
# process, with `seq` stamped there, per connection.
#
# A test class includes WebSocketTestHelpers, a LiveMultiprocess helper
# module, then this, and defines skip_unless_transport_available and
# fragment_copies (how many lines the big-fragment test sends: Postgres
# caps a NOTIFY payload at 8000 bytes, Redis has no cap).
module LiveFanoutContract
  ROW = %(<li id="c-<%= locals[:id] %>"><%= locals[:text] %></li>).freeze

  def setup
    skip_unless_transport_available
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

  def test_contract_a_patch_rendered_here_reaches_a_client_on_another_process_with_its_seq
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

  def test_contract_seq_is_counted_per_connection_at_the_edge_not_by_the_publisher
    topic = unique_topic
    early = connect_and_subscribe(topic)
    2.times { @publisher.remove(topic, to: "#x") }
    assert_equal [1, 2], [next_frame(early)["seq"], next_frame(early)["seq"]]

    late = connect_and_subscribe(topic)
    @publisher.remove(topic, to: "#x")

    assert_equal 1, next_frame(late)["seq"], "a connection that joined late must start at 1"
    assert_equal 3, next_frame(early)["seq"]
  end

  def test_contract_a_topic_only_reaches_its_own_subscribers_across_the_hop
    mine = unique_topic
    other = unique_topic
    on_mine = connect_and_subscribe(mine)
    on_other = connect_and_subscribe(other)

    @publisher.remove(other, to: "#for-other")
    @publisher.remove(mine, to: "#for-mine")

    assert_equal "#for-mine", next_frame(on_mine)["target"]
    assert_equal "#for-other", next_frame(on_other)["target"]
  end

  # Quotes, backslashes, tabs and multi-byte characters, across the
  # fanout's envelope and its server, exactly.
  def test_contract_a_multiline_unicode_fragment_survives_the_hop_intact
    html = "<p title=\"a&b\">caffè ☃ \"quoted\"\n\ttabbed \\ backslash</p>\n" * fragment_copies
    with_frozen_views({ "big.erb" => "<%= raw(locals[:html]) %>" }) do
      topic = unique_topic
      client = connect_and_subscribe(topic)

      @publisher.patch(topic, to: "#big", partial: "big", html: html)

      assert_equal html, next_frame(client, timeout: 10)["html"]
    end
  end

  def test_contract_publishing_from_a_non_main_ractor_reaches_the_other_process
    with_frozen_views({ "row.erb" => ROW }) do
      topic = unique_topic
      client = connect_and_subscribe(topic)
      Monk::Live.configure(registry: @fanout)

      Ractor.new(topic) { |t| Monk::Live.patch(t, to: "#c-9", partial: "row", id: 9, text: "from a Ractor") }.value

      assert_equal %(<li id="c-9">from a Ractor</li>), next_frame(client)["html"]
    end
  end

  def test_contract_every_publish_verb_reaches_the_other_process_through_monk_live
    with_frozen_views({ "row.erb" => ROW }) do
      topic = unique_topic
      client = connect_and_subscribe(topic)
      Monk::Live.configure(registry: @fanout)

      Monk::Live.append(topic, to: "#list", partial: "row", id: 1, text: "appended")
      assert_equal %w[patch append #list], next_frame(client).values_at("op", "mode", "target")
      Monk::Live.prepend(topic, to: "#list", partial: "row", id: 2, text: "prepended")
      assert_equal %w[patch prepend #list], next_frame(client).values_at("op", "mode", "target")
      Monk::Live.remove(topic, to: "#c-1")
      assert_equal %w[patch remove #c-1], next_frame(client).values_at("op", "mode", "target")
      Monk::Live.batch(topic) do |b|
        b.remove(to: "#c-2")
        b.remove(to: "#c-3")
      end
      assert_equal "batch", next_frame(client)["op"]
    end
  end

  def test_contract_a_subscriber_in_the_publishing_process_gets_it_once_and_the_remote_one_too
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
