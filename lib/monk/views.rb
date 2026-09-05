require "erb"
require "cgi/escape"

require_relative "freeze_hooks"
require_relative "template_not_found_error"
require_relative "template_syntax_error"

module Monk
  # ERB templates, compiled once at Boot into real instance methods on a
  # module that Context includes, then frozen. Never compiled at request
  # time -- see docs/views.md for why that isn't a preference: a worker
  # Ractor can't hold a template cache (shared mutable state) and mustn't
  # install methods on a shared module, so the lazy-compile-and-cache
  # design every other Ruby template engine uses is unavailable here.
  #
  # What that buys, beyond safety: a template's syntax error fails the
  # boot naming file and line (ADR 0003's posture, applied to views), and
  # a render is a plain method call (~2.6us for a small template) rather
  # than an eval.
  module Views
    # An already-safe fragment: `h` passes it through instead of escaping
    # it. #to_s must return self, because ERB::Compiler hardcodes
    # `insert_cmd((expr).to_s)` and String#to_s downgrades a subclass
    # instance to a plain String -- which would silently strip the marker.
    class Raw < String
      def to_s
        self
      end
    end

    # Compiled template methods land here; Monk::Context includes it, so
    # `self` inside a template is the request's Context and bare `params`,
    # `render`, ivars set by the route, and every other Context helper
    # resolve exactly as they do in a route block.
    module Compiled
    end

    DEFAULT_ROOT = "views".freeze

    class << self
      # Every reader here is a plain attr_reader over an ivar initialized
      # eagerly below, never `@x ||= ...`: a lazy reader *writes* on first
      # access, and writing a module ivar from a non-main Ractor is an
      # isolation error. The request path only ever reads.
      attr_reader :root, :layout, :registry
      attr_writer :root, :layout

      # Escapes unless the value is already Raw, and returns Raw either
      # way -- so an explicit `<%= h(x) %>` isn't escaped twice by the
      # implicit `h` the compiler wraps every `<%= %>` in.
      # CGI.escapeHTML, not ERB::Util.html_escape, though they produce
      # byte-identical output: ERB's is not flagged Ractor-safe, so a
      # worker calling it raises Ractor::UnsafeError ("ractor unsafe
      # method called from not main ractor"). Found by
      # test/ractor_integration_test.rb, in a real worker, not by reading
      # either implementation.
      def h(value)
        return value if value.is_a?(Raw)

        Raw.new(CGI.escapeHTML(value.to_s))
      end

      def compile(name, source, path = "(erb)")
        method_name = method_name_for(name)
        Compiled.module_eval("def #{method_name}(locals = {}); #{compiled_source(source)}; end", path, 0)
        registry[name] = method_name
        name
      rescue SyntaxError => e
        raise Monk::TemplateSyntaxError, e.message.lines.first.to_s.chomp
      end

      def render(context, name, locals, layout: :default)
        outer = !context.rendering
        context.rendering = true
        inner = invoke(context, name, locals)
        wrapper = layout == :default ? (outer ? self.layout : nil) : layout
        wrapper ? invoke(context, wrapper, locals) { inner } : inner
      ensure
        context.rendering = false if outer
      end

      # Called from Base#freeze! (Seam B), via Monk.freeze_hooks: compile
      # every template under `root`, then seal the registry so worker
      # Ractors can read it. #dup first, so booting twice in one process
      # (two apps, or a test suite) doesn't hit the frozen hash.
      def freeze_registry!
        @registry = registry.dup
        compile_all!

        if @layout && !@registry.key?(@layout)
          raise Monk::TemplateNotFoundError,
            "layout #{@layout.inspect} doesn't exist (looked under #{root.inspect}; " \
            "known: #{@registry.keys.sort.inspect})"
        end

        @registry = Ractor.make_shareable(@registry)
        # #root and #layout are read on the request path (the not-found
        # message, layout resolution), and an unfrozen String in a module
        # ivar is unreadable from a worker Ractor at all -- the same
        # restriction Persistence::Registry#freeze_registry! exists for.
        @root = root.freeze
        @layout = layout.freeze
      end

      # Test-only: forgets every compiled template. The methods stay
      # defined on Compiled (harmless -- they're unreachable once the
      # registry no longer names them), since a module can't undefine
      # itself back to a clean slate cheaply.
      def reset!
        @registry = {}
        @root = DEFAULT_ROOT
        @layout = nil
      end

      private

      def compile_all!
        return unless root && Dir.exist?(root)

        Dir.glob("**/*.erb", base: root).sort.each do |relative|
          path = File.join(root, relative)
          compile(relative.delete_suffix(".erb"), File.read(path), path)
        end
      end

      def invoke(context, name, locals, &block)
        method_name = registry.fetch(name) do
          raise Monk::TemplateNotFoundError,
            "no template #{name.inspect} (looked under #{root.inspect}; " \
            "known: #{registry.keys.sort.inspect})"
        end

        context.send(method_name, locals, &block)
      end

      # `<%= %>` escapes by default -- a deliberate break from stock ERB,
      # where it doesn't. ERB::Compiler emits `insert_cmd((expr).to_s)`
      # for every insertion, so pointing insert_cmd at Views.h is the
      # whole implementation; `raw(x)` opts back out.
      def compiled_source(source)
        compiler = ERB::Compiler.new("-")
        compiler.pre_cmd = ["_erbout = +''"]
        compiler.post_cmd = ["Monk::Views::Raw.new(_erbout)"]
        compiler.put_cmd = "_erbout.<<"
        compiler.insert_cmd = "_erbout.<< Monk::Views.h"
        compiler.compile(source).first
      end

      def method_name_for(name)
        return registry[name] if registry.key?(name)

        base = "__monk_view_#{name.gsub(/[^A-Za-z0-9_]/, "_")}"
        return base unless Compiled.method_defined?(base)

        suffix = 2
        suffix += 1 while Compiled.method_defined?("#{base}_#{suffix}")
        "#{base}_#{suffix}"
      end
    end

    @registry = {}
    @root = DEFAULT_ROOT
    @layout = nil

    Monk.freeze_hooks << self
  end
end
