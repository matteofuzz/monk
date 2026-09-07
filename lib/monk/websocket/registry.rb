module Monk
  module WebSocket
    # A dedicated Ractor holding the live set of connection handles keyed by
    # an app-assigned channel/subject -- mirrors StateRactor's shape
    # (docs/ractor.md): the mutable Hash stays hidden inside this one
    # Ractor, and every call is a synchronous "ask" via a fresh
    # Ractor::Port, so registration/broadcast can never race each other.
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
              end
            reply_port.send(result)
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

      def broadcast(key, payload)
        ask(:broadcast, key, payload)
      end

      # Not part of Phase 4's own plan bullets, but needed to actually
      # observe step 17's "a crashed handler never leaks a stale registry
      # entry" claim from outside the registry, rather than trusting it.
      def count(key)
        ask(:count, key, nil)
      end

      private

      def ask(op, key, arg)
        reply_port = Ractor::Port.new
        @ractor.send([op, key, arg, reply_port])
        reply_port.receive
      ensure
        reply_port&.close
      end
    end
  end
end
