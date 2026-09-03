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
                keys[key].each { |port| port.send(arg) }
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
