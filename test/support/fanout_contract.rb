require "timeout"
require "monk/websocket"

# What PgFanout and RedisFanout do the same way: wrap a Registry for
# cross-process fan-out, usable the way Registry is (held behind a module
# constant, read from every connection's Ractor); deliver a sibling's
# broadcast and drop their own echo; subscribe only once #listen! is
# called, by the one process that holds sockets.
#
# A test class includes it, with WebSocketTestHelpers, and defines:
# - fanout_class, and new_fanout(registry), not listening yet;
# - unreachable_fanout, one whose server isn't there;
# - skip_unless_transport_available;
# - subscriber_count: the subscriber connections open on the server;
# - listening_fanout, and drop_listener, which drops that fanout's
#   subscriber connection the way a server restart would;
# - publish_malformed(key): a message no fanout sent;
# - current_publisher and publisher_closed?(publisher): this Ractor's
#   publishing connection.
module FanoutContract
  def test_contract_a_fanout_is_frozen_and_ractor_shareable
    skip_unless_transport_available
    fanout = new_fanout

    assert fanout.frozen?
    assert Ractor.shareable?(fanout)
  end

  # An app holds the fanout behind a module constant, read from inside a
  # connection's own Ractor.
  def test_contract_a_fanout_is_readable_as_a_module_constant_from_a_worker_ractor
    skip_unless_transport_available
    holder = Module.new
    holder.const_set(:REGISTRY, new_fanout)

    assert_equal 0, Ractor.new(holder) { |h| h::REGISTRY.count(:room1) }.value
  end

  def test_contract_register_unregister_and_count_reach_the_wrapped_registry
    skip_unless_transport_available
    fanout = new_fanout.listen!
    port = Ractor::Port.new

    fanout.register(:room1, port)
    assert_equal 1, fanout.count(:room1)
    fanout.unregister(:room1, port)
    assert_equal 0, fanout.count(:room1)

    fanout.register_many(%i[room1 room2], port)
    assert_equal [1, 1], [fanout.count(:room1), fanout.count(:room2)]
    fanout.unregister_many(%i[room1 room2], port)
    assert_equal [0, 0], [fanout.count(:room1), fanout.count(:room2)]
  ensure
    port&.close
  end

  # A publish-only process (bin/server, bin/jobs) builds the same fanout
  # from the same config/live.rb, and never hears other processes.
  def test_contract_constructing_opens_no_subscriber_connection
    skip_unless_transport_available
    before = subscriber_count
    new_fanout

    assert_equal before, subscriber_count
  end

  # #listen! returns once the subscription is in effect, so a broadcast
  # sent right after it can't be missed.
  def test_contract_listen_opens_one_subscriber_connection_and_is_idempotent
    skip_unless_transport_available
    fanout = new_fanout
    before = subscriber_count

    assert_same fanout, fanout.listen!
    assert_equal before + 1, subscriber_count
    fanout.listen!
    assert_equal before + 1, subscriber_count
  end

  # A socket registered on a fanout that isn't listening would never get
  # another process's broadcasts, silently.
  def test_contract_register_before_listen_raises
    skip_unless_transport_available
    fanout = new_fanout
    port = Ractor::Port.new

    error = assert_raises(Monk::WebSocket::NotListeningError) { fanout.register(:room1, port) }
    assert_match(/#register before #listen!/, error.message)
    error = assert_raises(Monk::WebSocket::NotListeningError) { fanout.register_many(%i[room1], port) }
    assert_match(/#register_many before #listen!/, error.message)
  ensure
    port&.close
  end

  # In the WS process's boot, not in a background Ractor nobody watches.
  def test_contract_listen_raises_when_the_server_is_unreachable
    fanout = unreachable_fanout

    error = assert_raises(Monk::WebSocket::ListenError) { fanout.listen! }
    assert_match(/\A#{fanout_class.name}#listen! couldn't subscribe: /, error.message)
    assert_raises(Monk::WebSocket::NotListeningError) { fanout.register(:room1, Ractor::Port.new) }
  end

  def test_contract_a_broadcast_reaches_a_connection_registered_on_a_sibling
    skip_unless_transport_available
    sender = new_fanout
    port = Ractor::Port.new
    listening_fanout.register(:room1, port)

    sender.broadcast(:room1, "hello from A")

    assert_equal "hello from A", Timeout.timeout(2) { port.receive }
  ensure
    port&.close
  end

  # Without the origin tag, A's own subscriber would relay A's broadcast
  # into A's registry a second time.
  def test_contract_a_fanouts_own_broadcast_is_delivered_once
    skip_unless_transport_available
    fanout = new_fanout.listen!
    new_fanout.listen! # a sibling, so the broadcast really goes out and comes back
    port = Ractor::Port.new
    fanout.register(:room1, port)
    received = []
    reader = Thread.new { loop { received << port.receive } }

    fanout.broadcast(:room1, "only once")

    wait_until(timeout: 2) { received.any? }
    sleep 0.3 # time for an undropped echo to arrive
    assert_equal ["only once"], received
  ensure
    reader&.kill
    port&.close
  end

  def test_contract_disconnect_publisher_closes_this_ractors_publisher
    skip_unless_transport_available
    new_fanout.broadcast(:room1, "x")
    publisher = current_publisher
    refute publisher_closed?(publisher), "control: broadcasting opened it"

    fanout_class.disconnect_publisher

    assert publisher_closed?(publisher)
    assert_nil current_publisher
    fanout_class.disconnect_publisher # none left: a no-op
  end

  # A dropped subscriber connection (a restart, a failover) is reopened;
  # what was published meanwhile is lost, so every open socket is asked
  # to close and its page resyncs. A broadcast after that arrives as usual.
  def test_contract_after_a_dropped_connection_sockets_are_asked_to_close_and_broadcasts_arrive
    skip_unless_transport_available
    sender = new_fanout
    port = Ractor::Port.new
    listening_fanout.register(:room1, port)

    drop_listener

    assert_equal Monk::WebSocket::CloseRequest.new(code: 1011, reason: "missed broadcasts"),
      Timeout.timeout(5) { port.receive }
    sender.broadcast(:room1, "after the drop")
    assert_equal "after the drop", Timeout.timeout(2) { port.receive }
  ensure
    port&.close
  end

  def test_contract_a_malformed_message_is_skipped_and_the_next_one_arrives
    skip_unless_transport_available
    sender = new_fanout
    port = Ractor::Port.new
    listening_fanout.register(:room1, port)

    publish_malformed(:room1)
    sender.broadcast(:room1, "after the bad one")

    assert_equal "after the bad one", Timeout.timeout(2) { port.receive }
  ensure
    port&.close
  end
end
