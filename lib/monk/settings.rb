require_relative "freeze_hooks"

module Monk
  # A configuration facility for app-defined values -- MONK_ENV plus
  # anything else an app needs to configure. Declared once via #configure
  # (a DSL of #required/#optional key declarations) and read back via #[].
  # Deliberately separate from Persistence.register/Auth.configure -- see
  # docs/adr/0006-settings-alongside-persistence-and-auth-config.md.
  module Settings
    # MONK_ENV's fixed set of allowed values (CONTEXT.md's MONK_ENV entry).
    # :monk_env is implicitly declared below -- an app never has to
    # `required :monk_env` itself -- and its value is validated against
    # this set at Boot (#freeze_registry!), not before.
    MONK_ENV_VALUES = %w[development test staging production].freeze

    # Monk::Log's fixed set of allowed levels, ordered least to most severe.
    # Like :monk_env, :log_level is implicitly declared below and validated
    # against this set at Boot rather than before. Log::LEVELS aliases this
    # constant and reads it from worker Ractors on every #enabled? call, so
    # unlike MONK_ENV_VALUES this needs Ractor.make_shareable, not just
    # #freeze -- an Array#freeze only freezes the array itself, not the
    # strings inside, and a worker reading a non-shareable constant raises
    # Ractor::IsolationError.
    LOG_LEVEL_VALUES = Ractor.make_shareable(%w[debug info warn error])

    # public_url, and the WebSocket origins defaulting to it, are an origin:
    # scheme, host and port, nothing after. A browser's Origin header never
    # has a trailing slash, so with one every signed-in socket is refused.
    ORIGIN = %r{\Ahttps?://[^/?#@\s]+\z}

    # A placeholder domain, never a real one: example.com/.net/.org (the
    # deploy template's app.example.com) and the reserved .example, .test
    # and .invalid (RFC 2606). localhost and IPs pass: the deploy stack run
    # locally in production mode is on https://localhost.
    PLACEHOLDER_HOST = /(\A|\.)example\.(com|net|org)\z|(\A|\.)(example|test|invalid)\z/i

    DEFAULT_DECLARATIONS = {
      monk_env: { required: false, default: "development" },
      log_level: { required: false, default: "info" },
    }.freeze

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

        validate_monk_env!(values[:monk_env])
        validate_log_level!(values[:log_level])
        # Declared by the app (config/settings.rb, config/live.rb), but read
        # by Monk itself: Auth's magic links, Live's socket, WebSocket's
        # allowed origins. So Monk checks them, when they're declared.
        deployed = !%w[development test].include?(values[:monk_env])
        validate_public_url!(values[:public_url], deployed) if values.key?(:public_url)
        validate_live_ws_url!(values[:live_ws_url]) if deployed && values.key?(:live_ws_url)

        @frozen_values = Ractor.make_shareable(values)
        @booted = true
      end

      # Test-only.
      def reset!
        @declarations = DEFAULT_DECLARATIONS.dup
        @frozen_values = nil
        @booted = false
      end

      private

      def validate_monk_env!(value)
        return if MONK_ENV_VALUES.include?(value)

        raise InvalidMonkEnvError, "MONK_ENV must be one of #{MONK_ENV_VALUES.join(", ")}, got #{value.inspect}"
      end

      def validate_log_level!(value)
        return if LOG_LEVEL_VALUES.include?(value)

        raise InvalidLogLevelError, "LOG_LEVEL must be one of #{LOG_LEVEL_VALUES.join(", ")}, got #{value.inspect}"
      end

      def validate_public_url!(value, deployed)
        unless value.to_s.match?(ORIGIN)
          raise InvalidSettingError, "PUBLIC_URL must be an origin, scheme and host only (https://app.your-domain.com, " \
                                     "no path or trailing slash), got #{value.inspect}"
        end
        return unless deployed

        unless value.start_with?("https://")
          raise InvalidSettingError, "PUBLIC_URL must be https:// outside development and test: the session cookie " \
                                     "is Secure, so over http:// nobody stays signed in. Got #{value.inspect}"
        end
        host = value.delete_prefix("https://").sub(/:\d+\z/, "")
        return unless host.match?(PLACEHOLDER_HOST)

        raise InvalidSettingError, "PUBLIC_URL #{value.inspect} is a placeholder: set it to this app's real origin " \
                                   "(https://localhost for the deploy stack run locally)"
      end

      def validate_live_ws_url!(value)
        return if value.to_s.start_with?("wss://")

        raise InvalidSettingError, "LIVE_WS_URL must be wss:// outside development and test: an https:// page can't " \
                                   "open a ws:// socket. Got #{value.inspect} (unset, it's PUBLIC_URL's /ws)"
      end

      def declarations
        @declarations ||= DEFAULT_DECLARATIONS.dup
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
