require_relative "freeze_hooks"

module Monk
  # A configuration facility for app-defined values -- MONK_ENV plus
  # anything else an app needs to configure. Declared once via #configure
  # (a DSL of #required/#optional key declarations) and read back via #[].
  # Deliberately separate from Persistence.register/Auth.configure -- see
  # docs/adr/0006-settings-alongside-persistence-and-auth-config.md.
  module Settings
    # The DSL #configure's block runs against. Kept as its own object,
    # rather than instance_eval'd straight against Settings' singleton
    # class, so #required/#optional don't leak onto Settings' own public
    # interface (#[], #configure) inside the block.
    class DSL
      def initialize(declarations)
        @declarations = declarations
      end

      def required(key)
        declare(key, required: true, default: nil)
      end

      def optional(key, default:)
        declare(key, required: false, default: default)
      end

      private

      def declare(key, required:, default:)
        key = key.to_sym
        raise DuplicateSettingError, "#{key.inspect} is already declared" if @declarations.key?(key)

        @declarations[key] = { required: required, default: default }
      end
    end

    class << self
      def configure(&block)
        raise SettingsFrozenError, "Settings can't be configured after Boot" if booted?

        DSL.new(declarations).instance_eval(&block)
      end

      # A key's value. Before Boot, reads ENV live (its uppercased name)
      # or the declared default -- config/settings.rb and boot-time code
      # in config.ru need that. After Boot, reads the frozen snapshot
      # instead: ENV is main-Ractor state, so a per-request read from a
      # worker Ractor is exactly the hazard docs/persistence-ractor-
      # connections.md keeps naming. Reading a key nobody declared raises
      # rather than returning nil, either way.
      def [](key)
        key = key.to_sym

        if booted?
          raise UnknownSettingError, "no setting #{key.inspect} was declared" unless frozen_values.key?(key)

          return frozen_values.fetch(key)
        end

        declaration = declarations.fetch(key) { raise UnknownSettingError, "no setting #{key.inspect} was declared" }
        ENV.fetch(env_var_name(key)) { declaration[:default] }
      end

      def booted?
        !!@booted
      end

      # Called from Base#freeze! (Seam B), via Monk.freeze_hooks. Every
      # required key must be present in ENV or this raises naming it;
      # every declared key's resolved value is then frozen and made
      # Ractor.shareable?, so a worker Ractor can read it after Boot
      # without Ractor::IsolationError.
      def freeze_registry!
        values = declarations.each_with_object({}) do |(key, declaration), result|
          if declaration[:required] && !ENV.key?(env_var_name(key))
            raise MissingSettingError, "required setting #{key.inspect} (ENV[#{env_var_name(key).inspect}]) is not set"
          end

          result[key] = ENV.fetch(env_var_name(key)) { declaration[:default] }
        end

        @frozen_values = Ractor.make_shareable(values)
        @booted = true
      end

      # Test-only.
      def reset!
        @declarations = {}
        @frozen_values = nil
        @booted = false
      end

      private

      def declarations
        @declarations ||= {}
      end

      # A plain reader, not `@frozen_values ||= ...`: freeze_registry!
      # always sets this alongside @booted, and a lazy write here would
      # be a write to a module ivar from whichever Ractor first reads it
      # after Boot -- exactly the isolation error this method exists to
      # avoid.
      def frozen_values
        @frozen_values
      end

      def env_var_name(key)
        key.to_s.upcase
      end
    end

    Monk.freeze_hooks << self
  end
end
