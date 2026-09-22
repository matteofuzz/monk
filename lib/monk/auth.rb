require "securerandom"
require "digest"
require "openssl"

require_relative "freeze_hooks"
require_relative "auth/errors"
require_relative "auth/login_token"
require_relative "auth/session"
require_relative "auth/helpers"
require_relative "auth/rate_limiter"

module Monk
  # Passwordless token auth. Opt-in: require "monk/auth" explicitly --
  # `require "monk"` alone does not load this, since it depends on a
  # persistence backend the app may not use (docs/design/auth-sessions.md).
  module Auth
    REQUIRED_CONFIG_KEYS = %i[db_name secret login_ttl session_ttl].freeze

    class << self
      # Called from Base#freeze! (Seam B), via Monk.freeze_hooks. Freezes
      # the value, not the module -- Monk::Auth is always Ractor.shareable?
      # regardless of its ivars, so freezing the module itself would do
      # nothing (docs/design/persistence-ractor-connections.md "Phase 4/5 finding").
      def freeze_registry!
        @config = Ractor.make_shareable(@config)
        freeze_rqrcode!
      end

      def configure(db_name: nil, secret: nil, login_ttl: nil, session_ttl: nil, redirect_allowlist: [], secure: true)
        config = {
          db_name: db_name, secret: secret, login_ttl: login_ttl, session_ttl: session_ttl,
          redirect_allowlist: redirect_allowlist, secure: secure,
        }

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

      def request_login(email, redirect_to: nil)
        ensure_configured!
        if redirect_to && !config[:redirect_allowlist].include?(redirect_to)
          raise Monk::InvalidRedirectError, "#{redirect_to.inspect} is not in Monk::Auth's redirect_allowlist"
        end

        raw = SecureRandom.urlsafe_base64(32)

        LoginToken.create(
          email: email,
          token_hash: hash_token(raw),
          redirect_to: redirect_to,
          expires_at: Time.now + config[:login_ttl],
        )

        raw
      end

      # Convenience for an app's own login-request handler: prints a
      # magic link to the dev console (and log/development.log via
      # Monk::Log.info), plus a scannable QR code beneath it if the
      # optional `rqrcode` gem is in the app's own Gemfile -- makes
      # testing the login flow from a second device (another browser, a
      # phone) trivial without a mailer. A no-op outside development,
      # same posture as every other dev-only escape hatch in this
      # framework (docs/history/secure-cookie-dev-http.md).
      #
      # subject: is optional context for the printed line only (e.g. the
      # email being logged in) -- useful once more than one login is in
      # flight at a time (two test users, two devices), never persisted
      # or otherwise part of the token itself.
      #
      # rqrcode is opt-in, same as pg/redis: not a runtime dependency of
      # monk itself (see monk.gemspec) -- an app that wants the QR code
      # declares it in its own Gemfile. Without it, this still logs the
      # plain link, just no QR beneath it.
      def log_dev_link(link, subject: nil)
        return unless Monk.env.development?

        line = subject ? "[dev] magic link for #{subject}: #{link}" : "[dev] magic link: #{link}"
        $stdout.puts(line)
        $stdout.flush
        Monk::Log.info(line)

        begin
          require "rqrcode"
        rescue LoadError
          return
        end

        $stdout.puts(compact_qr(RQRCode::QRCode.new(link, level: :l)))
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

        { token: session_raw, subject: row[:email], expires_at: expires_at, redirect_to: row[:redirect_to] }
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
      # query-DSL scope for a hygiene task (docs/design/auth-sessions.md).
      def sweep!
        ensure_configured!
        Monk::Persistence::Pg.checkout(config[:db_name]) do |conn|
          now = Time.now
          login_tokens_deleted = conn.exec_params("DELETE FROM login_tokens WHERE expires_at < $1", [now]).cmd_tuples
          sessions_deleted = conn.exec_params("DELETE FROM sessions WHERE expires_at < $1", [now]).cmd_tuples
          { login_tokens: login_tokens_deleted, sessions: sessions_deleted }
        end
      end

      # Stateless double-submit CSRF token, derived not stored
      # (docs/design/auth-sessions.md's "CSRF: stateless double-submit, no third
      # table") -- the one HMAC implementation set_session_cookie and
      # require_csrf! both call, so there's no second place this could
      # drift out of sync.
      def csrf_token_for(session_token)
        OpenSSL::HMAC.hexdigest("SHA256", config[:secret], session_token)
      end

      private

      # as_ansi spends two columns and one line per module, so even a
      # short link fills the terminal. Half-block characters pack two
      # module rows into one line and one column per module (roughly a
      # quarter of the area); the explicit black-on-white colors keep it
      # scannable on dark terminals too. Quiet zone is 2 modules, below
      # the spec's 4 but reliable for phone cameras against a white
      # background.
      def compact_qr(qr, quiet_zone: 2)
        width = qr.modules.size + quiet_zone * 2
        blank = Array.new(quiet_zone) { Array.new(width, false) }
        grid = blank + qr.modules.map { |row| Array.new(quiet_zone, false) + row + Array.new(quiet_zone, false) } + blank
        grid << Array.new(width, false) if grid.size.odd?

        grid.each_slice(2).map do |top, bottom|
          cells = top.zip(bottom).map do |t, b|
            if t && b then "\u2588"
            elsif t then "\u2580"
            elsif b then "\u2584"
            else " "
            end
          end
          # dark modules are the glyph (black fg) on a white bg
          "\e[30;47m#{cells.join}\e[0m"
        end.join("\n")
      end

      def ensure_configured!
        raise Monk::AuthNotConfiguredError,
          "Monk::Auth is not configured -- call Monk::Auth.configure first" unless @config
      end

      def hash_token(raw)
        Digest::SHA256.hexdigest(raw)
      end

      # rqrcode (used by log_dev_link) is a third-party gem with no
      # Ractor awareness of its own: several of its lookup tables
      # (RQRCodeCore::QRUtil::PATTERN_POSITION_TABLE and siblings) are
      # ordinary, unfrozen constants. Reading one of those from a worker
      # Ractor -- which is exactly what happens the first time
      # log_dev_link runs inside a real request under Kino -- raises
      # Ractor::IsolationError regardless of which Ractor originally
      # required the gem; only the object's own shareability matters
      # (confirmed live: requiring rqrcode in the main Ractor first does
      # not help). Walking its constants here, at boot in the main
      # Ractor, and freezing each one is the same fix
      # docs/design/persistence-ractor-connections.md documents for this exact
      # class of problem elsewhere in the stack. A no-op if the app
      # hasn't added rqrcode to its own Gemfile (see log_dev_link).
      def freeze_rqrcode!
        require "rqrcode"
      rescue LoadError
        nil
      else
        freeze_constants!(RQRCodeCore)
        freeze_constants!(RQRCode)
      end

      def freeze_constants!(mod, seen = {}.compare_by_identity)
        return if seen[mod]
        seen[mod] = true

        mod.constants(false).each do |name|
          value = mod.const_get(name)
          if value.is_a?(Module)
            freeze_constants!(value, seen) if value.name&.start_with?("RQRCode")
          else
            Ractor.make_shareable(value)
          end
        end
      end
    end

    Monk.freeze_hooks << self
  end
end
