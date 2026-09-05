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
        DSL.new(declarations).instance_eval(&block)
      end

      # A key's value: ENV[its uppercased name], or the declared default
      # if ENV doesn't have it. Reading a key nobody declared raises
      # rather than returning nil -- a typo becomes a loud error at the
      # read site instead of a silent nil surfacing somewhere else.
      def [](key)
        key = key.to_sym
        declaration = declarations.fetch(key) { raise UnknownSettingError, "no setting #{key.inspect} was declared" }

        ENV.fetch(env_var_name(key)) { declaration[:default] }
      end

      # Test-only.
      def reset!
        @declarations = {}
      end

      private

      def declarations
        @declarations ||= {}
      end

      def env_var_name(key)
        key.to_s.upcase
      end
    end
  end
end
