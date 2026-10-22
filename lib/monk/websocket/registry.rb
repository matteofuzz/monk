module Monk
  module WebSocket
    # Sent through a registered port instead of a payload: the socket
    # behind it closes with this code and reason. Registry#close_all sends
    # it; Connection's and Live::Session's relays act on it.
    CloseRequest = Data.define(:code, :reason)

    # A dedicated Ractor holding the live set of connection handles keyed by
    # an app-assigned channel/subject -- mirrors StateRactor's shape
    # (docs/design/ractor.md): the mutable Hash stays hidden inside this one
    # Ractor, and every call is a synchronous "ask" answered on the
    # caller's reply port, so registration/broadcast can never race each
    # other.
    class Registry
      def initialize
        @ractor = Ractor.new do
          keys = Hash.new { |h, k| h[k] = [] }

          loop do
            op, key, arg, reply_port = Ractor.receive
            result =
              case op
              when :register
                keys[key] << arg unless keys[key].include?(arg)
                true
              when :unregister
                keys[key].delete(arg)
                true
              when :register_many
                # key is the Array of keys: a Live subscribe's topics in
                # one ask, not one each.
                key.each { |k| keys[k] << arg unless keys[k].include?(arg) }
                true
              when :unregister_many
                key.each { |k| keys[k].delete(arg) }
                true
              when :broadcast
                # A port can be closed out from under this loop without
                # ever going through #unregister -- e.g. the owning
                # connection Ractor dies before its own cleanup runs.
                # port.send on a closed port raises Ractor::ClosedError;
                # left unguarded, that exception would propagate out of
                # this single-threaded loop and kill the *registry*
                # Ractor, taking down delivery for every key, not just
                # this one. Rescuing it here, per port, keeps the
                # broadcast going for every other subscriber and also
                # drops the dead port from keys[key] -- self-healing the
                # stale entry #unregister was supposed to have caught.
                keys[key].reject! do |port|
                  port.send(arg)
                  false
                rescue Ractor::ClosedError
                  true
                end
                true
              when :count
                keys[key].size
              when :close_all
                # Once per port: a Live page holds one port for all its
                # topics. Entries stay until each connection's own cleanup
                # unregisters them, as on any other close.
                ports = keys.values.flatten.uniq
                ports.each do |port|
                  port.send(arg)
                rescue Ractor::ClosedError
                  nil
                end
                ports.size
              end
            begin
              reply_port.send(result)
            rescue Ractor::ClosedError
              # The caller gave up on this ask (its thread was killed while
              # it waited) and closed its port: nobody to answer, and no
              # reason to end the registry for every other caller.
            end
          end
        end
        freeze
      end

      def register(key, port)
        ask(:register, key, port)
      end

      def unregister(key, port)
        ask(:unregister, key, port)
      end

      # register for each of keys, in one ask: one message and one reply
      # instead of one each (docs/plan-ws-connect-ceiling.md, item 5).
      def register_many(keys, port)
        ask(:register_many, keys, port)
      end

      def unregister_many(keys, port)
        ask(:unregister_many, keys, port)
      end

      def broadcast(key, payload)
        ask(:broadcast, key, payload)
      end

      # Not part of Phase 4's own plan bullets, but needed to actually
      # observe step 17's "a crashed handler never leaks a stale registry
      # entry" claim from outside the registry, rather than trusting it.
      def count(key)
        ask(:count, key, nil)
      end

      # Closes every registered connection's socket with code and reason,
      # so each client reconnects -- a fanout's subscriber does this after
      # missing broadcasts, to make every page resync. Returns how many
      # connections were asked to close.
      def close_all(code, reason)
        ask(:close_all, nil, Ractor.make_shareable(CloseRequest.new(code: code, reason: reason.to_s)))
      end

      # Nothing to listen to: every broadcast reaching this registry comes
      # from this process. Here so a WS process calls #listen! the same
      # way whether it holds a Registry or a RedisFanout/PgFanout around
      # one.
      def listen! = self

      private

      # An ask is synchronous, so a fiber has at most one outstanding: its
      # reply port is made once and reused (a Port is an allocation and a
      # message each), taken out of fiber storage while the ask is in
      # flight. An ask cut short (the thread killed while it waits) closes
      # the port instead of putting it back, so its late reply can't be
      # read as the next ask's.
      def ask(op, key, arg)
        reply_port = Thread.current[:monk_registry_reply_port] || Ractor::Port.new
        Thread.current[:monk_registry_reply_port] = nil
        @ractor.send([op, key, arg, reply_port])
        result = reply_port.receive
        Thread.current[:monk_registry_reply_port] = reply_port
        reply_port = nil
        result
      rescue Ractor::ClosedError
        # The registry Ractor itself can be gone by the time this runs --
        # e.g. process-wide shutdown (Ctrl+C) tearing down Ractors in
        # whatever order, with a connection's own cleanup (Connection#
        # unsubscribe!, called from Server.serve's ensure) losing the race
        # against the registry's. Nothing on the other end to reply to a
        # dead call anyway; nil is indistinguishable from "the process is
        # already exiting" to every caller here (register/unregister/
        # broadcast ignore their return value, and #count is never read
        # this late).
        nil
      ensure
        reply_port&.close
      end
    end
  end
end
