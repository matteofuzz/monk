require "securerandom"
require "digest"

require_relative "missing_auth_config_error"
require_relative "persistence/pg"
require_relative "auth/login_token"
require_relative "auth/session"

module Monk
  # Passwordless token auth. Opt-in: require "monk/auth" explicitly --
  # `require "monk"` alone does not load this, since it depends on a
  # persistence backend the app may not use (docs/auth-sessions.md).
  module Auth
    REQUIRED_CONFIG_KEYS = %i[db_name secret login_ttl session_ttl].freeze

    class << self
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

      def request_login(email)
        raw = SecureRandom.urlsafe_base64(32)

        LoginToken.create(
          email: email,
          token_hash: hash_token(raw),
          expires_at: Time.now + config[:login_ttl],
        )

        raw
      end

      def redeem(raw)
        return nil if raw.nil? || raw.empty?

        row = LoginToken.where(token_hash: hash_token(raw)).first
        return nil unless row
        return nil if row[:expires_at] <= Time.now

        LoginToken.update(row[:id], used_at: Time.now)

        session_raw = SecureRandom.urlsafe_base64(32)
        expires_at = Time.now + config[:session_ttl]
        Session.create(subject: row[:email], token_hash: hash_token(session_raw), expires_at: expires_at)

        { token: session_raw, subject: row[:email], expires_at: expires_at }
      end

      private

      def hash_token(raw)
        Digest::SHA256.hexdigest(raw)
      end
    end
  end
end
