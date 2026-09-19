module Monk
  module Live
    # Renders a fragment once, wraps it in an Envelope, and broadcasts the
    # frozen JSON to every subscriber of a topic (ADR 0010). Wraps anything
    # with Registry's #broadcast, so a RedisFanout makes it cross-process
    # without this class knowing (ADR 0008). Frozen, so a module-level
    # publisher is readable from any Ractor.
    #
    # `to:`, `partial:` and `mode:` are reserved keywords; every other
    # keyword is a local for the partial (read as `locals[:name]`).
    class Publisher
      def initialize(registry)
        @registry = registry
        freeze
      end

      def patch(topic, to:, partial:, mode: :morph, **locals)
        broadcast(topic, Publisher.build_op(to, partial, mode, locals))
      end

      def append(topic, to:, partial:, **locals)
        patch(topic, to: to, partial: partial, mode: :append, **locals)
      end

      def prepend(topic, to:, partial:, **locals)
        patch(topic, to: to, partial: partial, mode: :prepend, **locals)
      end

      def remove(topic, to:)
        broadcast(topic, Publisher.build_op(to, nil, :remove, {}))
      end

      # Every op renders inside the block, so a failure raises before
      # anything is sent; an empty batch sends nothing.
      def batch(topic)
        builder = Batch.new
        yield builder
        return true if builder.ops.empty?

        broadcast(topic, Envelope.batch(builder.ops))
      end

      # Collects ops for #batch; same vocabulary as the publisher itself.
      class Batch
        attr_reader :ops

        def initialize
          @ops = []
        end

        def patch(to:, partial:, mode: :morph, **locals)
          @ops << Publisher.build_op(to, partial, mode, locals)
        end

        def append(to:, partial:, **locals)
          patch(to: to, partial: partial, mode: :append, **locals)
        end

        def prepend(to:, partial:, **locals)
          patch(to: to, partial: partial, mode: :prepend, **locals)
        end

        def remove(to:)
          @ops << Publisher.build_op(to, nil, :remove, {})
        end
      end

      # Validates before rendering, so a bad mode or target never costs a
      # render (or a half-built batch).
      def self.build_op(target, partial, mode, locals)
        Envelope.check_target!(target)
        Envelope.check_mode!(mode)
        return Envelope.patch(target: target, mode: :remove) if mode == :remove

        Envelope.patch(target: target, mode: mode, html: Renderer.render(partial, **locals))
      end

      private

      # Topics are Symbols on the Registry (RedisFanout's channel names
      # come back as Symbols), Strings in app code.
      def broadcast(topic, envelope)
        unless topic.is_a?(String) || topic.is_a?(Symbol)
          raise ArgumentError, "topic must be a String or Symbol, got #{topic.inspect}"
        end

        @registry.broadcast(topic.to_sym, Envelope.encode(envelope))
      end
    end
  end
end
