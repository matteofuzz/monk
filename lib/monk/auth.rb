require "securerandom"
require "digest"

require_relative "freeze_hooks"
require_relative "missing_auth_config_error"
require_relative "auth_not_configured_error"
require_relative "persistence/pg"
require_relative "auth/login_token"
require_relative "auth/session"
require_relative "auth/helpers"

module Monk
  # Passwordless token auth. Opt-in: require "monk/auth" explicitly --
  # `require "monk"` alone does not load this, since it depends on a
  # persistence backend the app may not use (docs/auth-sessions.md).
  module Auth
    REQUIRED_CONFIG_KEYS = %i[db_name secret login_ttl session_ttl].freeze

    class << self
      # Called from Base#freeze! (Seam B), via Monk.freeze_hooks. Freezes
      # the value, not the module -- Monk::Auth is always Ractor.shareable?
      # regardless of its ivars, so freezing the module itself would do
      # nothing (docs/persistence-ractor-connections.md "Phase 4/5 finding").
      def freeze_registry!
        @config = Ractor.make_shareable(@config)
      end

      def configure(db_name: nil, secret: nil, login_ttl: nil, session_ttl: nil)
        config = { db_name: db_name, secret: secret, login_ttl: login_ttl, session_ttl: session_ttl }

        REQUIRED_CONFIG_KEYS.each do |key|
          raise Monk::MissingAuthConfigError,
            "Monk::Auth.configure is missing required key #{key.inspect}" if config[key].nil?
        end

        LoginToken.db_name = db_name
        Session.db_name = db_name

        @config = config
      end

      def config
        @config
      end

      # Test-only: drops the current config. Not part of the app-facing API.
      def reset!
        @config = nil
      end

      def request_login(email)
        ensure_configured!
        raw = SecureRandom.urlsafe_base64(32)

        LoginToken.create(
          email: email,
          token_hash: hash_token(raw),
          expires_at: Time.now + config[:login_ttl],
        )

        raw
      end

      def redeem(raw)
        ensure_configured!
        return nil if raw.nil? || raw.empty?

        row = LoginToken.where(token_hash: hash_token(raw)).first
        return nil unless row
        return nil if row[:expires_at] <= Time.now

        claimed = LoginToken.claim({ id: row[:id], used_at: nil }, used_at: Time.now)
        return nil unless claimed

        session_raw = SecureRandom.urlsafe_base64(32)
        expires_at = Time.now + config[:session_ttl]
        Session.create(subject: row[:email], token_hash: hash_token(session_raw), expires_at: expires_at)

        { token: session_raw, subject: row[:email], expires_at: expires_at }
      end

      def verify(raw)
        ensure_configured!
        return nil if raw.nil? || raw.empty?

        row = Session.where(token_hash: hash_token(raw)).first
        return nil unless row
        return nil if row[:revoked_at]
        return nil if row[:expires_at] <= Time.now

        row[:subject]
      end

      def revoke(raw)
        ensure_configured!
        row = Session.where(token_hash: hash_token(raw)).first
        return false unless row

        Session.update(row[:id], revoked_at: Time.now)
        true
      end

      def revoke_all(subject)
        ensure_configured!
        rows = Session.where(subject: subject).select { |row| row[:revoked_at].nil? }
        now = Time.now
        rows.each { |row| Session.update(row[:id], revoked_at: now) }
        rows.size
      end

      # Deliberately not grown onto Model: a `<` comparison is real
      # query-DSL scope for a hygiene task (docs/auth-sessions.md).
      def sweep!
        ensure_configured!
        Monk::Persistence::Pg.checkout(config[:db_name]) do |conn|
          now = Time.now
          login_tokens_deleted = conn.exec_params("DELETE FROM login_tokens WHERE expires_at < $1", [now]).cmd_tuples
          sessions_deleted = conn.exec_params("DELETE FROM sessions WHERE expires_at < $1", [now]).cmd_tuples
          { login_tokens: login_tokens_deleted, sessions: sessions_deleted }
        end
      end

      private

      def ensure_configured!
        raise Monk::AuthNotConfiguredError,
          "Monk::Auth is not configured -- call Monk::Auth.configure first" unless @config
      end

      def hash_token(raw)
        Digest::SHA256.hexdigest(raw)
      end
    end

    Monk.freeze_hooks << self
  end
end
