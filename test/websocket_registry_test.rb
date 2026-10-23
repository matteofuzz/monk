require_relative "test_helper"
require "monk/websocket"

class WebSocketRegistryTest < Minitest::Test
  # No real socket needed to prove the registry's own bookkeeping
  # (docs/history/plan-websocket.md step 16) -- a bare Ractor::Port stands in for
  # whatever a real connection would register.
  def test_broadcast_delivers_to_every_port_registered_under_the_key
    registry = Monk::WebSocket::Registry.new
    port_a = Ractor::Port.new
    port_b = Ractor::Port.new

    registry.register(:room1, port_a)
    registry.register(:room1, port_b)
    registry.broadcast(:room1, "hi")

    assert_equal "hi", port_a.receive
    assert_equal "hi", port_b.receive
  ensure
    port_a&.close
    port_b&.close
  end

  # Same interface as the fanouts, so a WS process calls #listen! whichever
  # one it holds: an in-process Registry has nothing to listen to.
  def test_listen_bang_is_a_no_op_returning_the_registry
    registry = Monk::WebSocket::Registry.new

    assert_same registry, registry.listen!
  end

  def test_broadcast_does_not_deliver_to_a_port_registered_under_a_different_key
    registry = Monk::WebSocket::Registry.new
    other_key_port = Ractor::Port.new
    registry.register(:other_room, other_key_port)

    registry.broadcast(:room1, "hi")

    refute_delivered(other_key_port)
  ensure
    other_key_port&.close
  end

  def test_unregister_removes_the_port_from_future_broadcasts
    registry = Monk::WebSocket::Registry.new
    port = Ractor::Port.new
    registry.register(:room1, port)
    registry.unregister(:room1, port)

    registry.broadcast(:room1, "hi")

    refute_delivered(port)
  ensure
    port&.close
  end

  # docs/plan-ws-connect-ceiling.md item 5: a Live subscribe's topics in one
  # ask.
  def test_register_many_and_unregister_many_cover_every_key_in_one_ask
    registry = Monk::WebSocket::Registry.new
    port = Ractor::Port.new

    registry.register_many(%i[room1 room2 room1], port)
    assert_equal [1, 1], [registry.count(:room1), registry.count(:room2)]

    registry.broadcast(:room2, "hi")
    assert_equal "hi", port.receive

    registry.unregister_many(%i[room1 room2], port)
    assert_equal [0, 0], [registry.count(:room1), registry.count(:room2)]
  ensure
    port&.close
  end

  def test_asks_from_one_thread_reuse_its_reply_port
    registry = Monk::WebSocket::Registry.new
    registry.count(:room1)
    reply_port = Thread.current[:monk_registry_reply_port]
    registry.count(:room1)

    assert_kind_of Ractor::Port, reply_port
    assert_same reply_port, Thread.current[:monk_registry_reply_port]
  end

  # An ask whose caller gave up closes its reply port; answering it mustn't
  # end the registry for everyone else.
  def test_a_closed_reply_port_does_not_end_the_registry
    registry = Monk::WebSocket::Registry.new
    closed = Ractor::Port.new
    closed.close
    registry.instance_variable_get(:@ractor).send([:count, :room1, nil, closed])

    assert_equal 0, registry.count(:room1)
  end

  # Simulates the race gap 2 of docs/history/chat-gap-analysis.md describes: a
  # port closed out from under the registry without ever going through
  # #unregister (e.g. the owning connection Ractor died before its own
  # cleanup ran). Before the rescue in Registry#initialize, port.send
  # raising Ractor::ClosedError here would have propagated out of the
  # registry Ractor's own loop and killed it -- taking down delivery for
  # every key, not just this one.
  def test_broadcast_skips_a_closed_port_without_crashing_the_registry
    registry = Monk::WebSocket::Registry.new
    dead_port = Ractor::Port.new
    live_port = Ractor::Port.new
    registry.register(:room1, dead_port)
    registry.register(:room1, live_port)
    dead_port.close

    registry.broadcast(:room1, "hi")

    assert_equal "hi", live_port.receive
    # The registry Ractor is still alive and answering -- the crash this
    # guards against would otherwise have made every subsequent call hang
    # or raise.
    assert_equal 1, registry.count(:room1)
  ensure
    live_port&.close
  end

  def test_broadcast_removes_a_closed_port_so_later_broadcasts_do_not_retry_it
    registry = Monk::WebSocket::Registry.new
    dead_port = Ractor::Port.new
    registry.register(:room1, dead_port)
    dead_port.close

    registry.broadcast(:room1, "hi")

    assert_equal 0, registry.count(:room1)
  end

  # Simulates the shutdown race a bare Ctrl+C with live connections hits:
  # Server.serve's ensure block calls Connection#unsubscribe! -> #unregister
  # on every exit path, but the registry's own dedicated Ractor can already
  # be gone by then (process-wide teardown, no ordering guarantee between
  # Ractors). @ractor.send onto an already-terminated Ractor raises
  # Ractor::ClosedError same as it would in that real race -- a terminated
  # Ractor stands in for "registry Ractor died first" without needing to
  # actually race a live process shutdown.
  def test_ask_survives_the_registry_ractor_already_being_gone
    # Registry.new freezes the instance, so a live one can't have its
    # @ractor swapped out from a test -- .allocate skips #initialize (and
    # the freeze at the end of it) to install an already-dead Ractor in
    # its place instead.
    registry = Monk::WebSocket::Registry.allocate
    dead_ractor = Ractor.new {}
    dead_ractor.value # wait for it to finish and close its own incoming port
    registry.instance_variable_set(:@ractor, dead_ractor)
    port = Ractor::Port.new

    assert_nil registry.register(:room1, port)
    assert_nil registry.unregister(:room1, port)
    assert_nil registry.broadcast(:room1, "hi")
    assert_nil registry.count(:room1)
  ensure
    port&.close
  end

  def test_count_reflects_registrations_and_unregistrations
    registry = Monk::WebSocket::Registry.new
    port = Ractor::Port.new

    assert_equal 0, registry.count(:room1)
    registry.register(:room1, port)
    assert_equal 1, registry.count(:room1)
    registry.unregister(:room1, port)
    assert_equal 0, registry.count(:room1)
  ensure
    port&.close
  end

  private

  # Ractor::Port has no non-blocking/"try" receive, so this is the same
  # bounded-wait shape persistence_test.rb already uses elsewhere in this
  # suite to assert a negative.
  def refute_delivered(port, timeout: 0.1)
    received = nil
    waiter = Thread.new { received = port.receive }
    delivered = waiter.join(timeout)
    waiter.kill unless delivered

    refute delivered, "expected nothing to be delivered, but got #{received.inspect}"
  end
end
