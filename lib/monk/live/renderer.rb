module Monk
  module Live
    # Renders a Monk::Views template to a String fragment, for pushing to
    # open browsers (ADR 0010) -- no HTTP response, no layout, and no
    # request behind it: a detached Monk::Context, so a live partial can
    # only see what it's given as locals. Callable from any Ractor once
    # views are frozen (Phase 0 spike: ~3us per render).
    module Renderer
      def self.render(partial, **locals)
        # Context#render's own `layout:` keyword would swallow this
        # silently and render the wrong thing (a layout around a
        # fragment), so it's rejected rather than treated as a local.
        if locals.key?(:layout)
          raise ArgumentError, "`layout` is reserved: a live fragment is never wrapped in a layout"
        end

        ensure_frozen!
        html = Monk::Context.new({}).render(partial, layout: false, **locals)
        # A plain, frozen String, not Views::Raw: frozen means Ractor-
        # shareable, so a broadcast hands every port a reference instead
        # of a copy (ADR 0010, measured in the Phase 0 fan-out spike).
        String.new(html).freeze
      end

      # Views are compiled and sealed by Monk.freeze! in the main Ractor.
      # Unfrozen, a render from a non-main Ractor dies with an opaque
      # Ractor::IsolationError from inside Monk::Views, and in the main
      # Ractor it would work by accident and then fail in production --
      # so both cases fail here, with the fix in the message (ADR 0003).
      def self.ensure_frozen!
        return if Ractor.shareable?(Monk::Views.registry)

        raise_not_frozen
      rescue Ractor::IsolationError
        raise_not_frozen
      end
      private_class_method :ensure_frozen!

      def self.raise_not_frozen
        raise Monk::Live::NotFrozenError,
          "Monk::Live can't render before views are frozen -- call Monk.freeze! (or Monk.boot(app)) " \
          "in the main Ractor first"
      end
      private_class_method :raise_not_frozen
    end
  end
end
