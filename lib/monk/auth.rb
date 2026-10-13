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

    # The login-email rate limit (docs/plan-auth-housekeeping.md decision
    # 5): records a request unless one was recorded for the address less
    # than $2 seconds ago. One statement, so racing requests for one
    # address let exactly one through; a refused request changes nothing.
    LOGIN_REQUEST_SQL = <<~SQL.freeze
      INSERT INTO login_requests (email) VALUES ($1)
      ON CONFLICT (email) DO UPDATE SET requested_at = now()
        WHERE login_requests.requested_at < now() - $2::int * interval '1 second'
      RETURNING 1
    SQL

    SWEEP_BATCH_SIZE = 10_000

    # sweep!'s statements, one batch each. Tokens and sessions expire by
    # the app's clock, as redeem and verify check them; login requests by
    # the database's, as allow_login_request? does.
    SWEEP_LOGIN_TOKENS_SQL = <<~SQL.freeze
      DELETE FROM login_tokens WHERE id IN (SELECT id FROM login_tokens WHERE expires_at < $1 LIMIT $2)
    SQL
    SWEEP_SESSIONS_SQL = <<~SQL.freeze
      DELETE FROM sessions WHERE id IN (SELECT id FROM sessions WHERE expires_at < $1 LIMIT $2)
    SQL
    SWEEP_LOGIN_REQUESTS_SQL = <<~SQL.freeze
      DELETE FROM login_requests WHERE email IN (
        SELECT email FROM login_requests WHERE requested_at < now() - $1::int * interval '1 second' LIMIT $2
      )
    SQL

    class << self
      # Called from Base#freeze! (Seam B), via Monk.freeze_hooks. Freezes
      # the value, not the module -- Monk::Auth is always Ractor.shareable?
      # regardless of its ivars, so freezing the module itself would do
      # nothing (docs/design/persistence-ractor-connections.md "Phase 4/5 finding").
      def freeze_registry!
        begin
          @config = Ractor.make_shareable(@config)
        rescue ArgumentError, Ractor::IsolationError => e
          raise Monk::UnshareableBlockError,
            "Monk::Auth.configure(deliver:) is not Ractor-shareable: #{e.message} " \
            "(build it where self is shareable, e.g. as a module constant at class/module-body " \
            "scope -- self at a script's top level, e.g. config/auth.rb itself, is not shareable, " \
            "same constraint as Monk::Live.authorize blocks)"
        end
        freeze_rqrcode!
      end

      # callback_path: is where the app's own callback route redeems a
      # token (GET "#{callback_path}/:token"). Monk doesn't define that
      # route, but builds links to it: login_link below, and so
      # Monk::Auth::SendLoginLink. login_request_interval: is the seconds
      # allow_login_request? makes an address wait between login emails.
      def configure(
        db_name: nil, secret: nil, login_ttl: nil, session_ttl: nil, redirect_allowlist: [], secure: true,
        deliver: nil, callback_path: "/auth/callback", login_request_interval: 60
      )
        config = {
          db_name: db_name, secret: secret, login_ttl: login_ttl, session_ttl: session_ttl,
          redirect_allowlist: redirect_allowlist, secure: secure, deliver: deliver,
          callback_path: checked_callback_path(callback_path),
          login_request_interval: checked_login_request_interval(login_request_interval),
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

      # The login-email rate limit, for the login route to check before it
      # sends or enqueues the link: true, and recorded, if no link was
      # requested for this address in the last login_request_interval
      # seconds; false otherwise. Per address, across every process. The
      # address is stripped and downcased for the limit only.
      #
      #   halt(429) unless Monk::Auth.allow_login_request?(email)
      def allow_login_request?(email)
        ensure_configured!
        unless email.is_a?(String) && !email.strip.empty?
          raise ArgumentError, "Monk::Auth.allow_login_request? needs an email address, got #{email.inspect}"
        end

        params = [email.strip.downcase, config[:login_request_interval]]
        Monk::Persistence::Pg.checkout(config[:db_name]) { |c| c.exec_params(LOGIN_REQUEST_SQL, params).ntuples == 1 }
      end

      # Test-only: forgets every login request, so the next test can log in
      # again at once. Refuses unless MONK_ENV is test.
      def clear_login_requests!
        unless Monk.env.test?
          raise Monk::ClearLoginRequestsOutsideTestsError,
            "Monk::Auth.clear_login_requests! lifts the login-email rate limit for every address, so it only " \
            "runs with MONK_ENV=test (this is #{Monk.env})"
        end

        ensure_configured!
        Monk::Persistence::Pg.checkout(config[:db_name]) { |c| c.exec("DELETE FROM login_requests") }
        nil
      end

      # The magic link for a raw token: the app's public_url
      # (config/settings.rb, a trusted origin -- never request headers like
      # X-Forwarded-Host, which any direct client can spoof), then
      # callback_path:, then the token.
      #
      #   Monk::Auth.login_link(token) # => "https://app.example/auth/callback/<token>"
      def login_link(token)
        ensure_configured!
        "#{Monk::Settings[:public_url]}#{config[:callback_path]}/#{token}"
      end

      # The single place an app's login-request handler calls to get a
      # magic link to its owner: uses the `deliver:` callable passed to
      # `configure` (e.g. wrapping a mailer or a provider's HTTP API) when
      # one is set, regardless of environment -- an app that wants to
      # exercise real delivery in development is free to. With no
      # `deliver:` configured, falls back to #log_dev_link in development
      # (see below), and raises everywhere else: a silent no-op here would
      # mean an app that forgot to wire delivery finds out only when a
      # user reports never receiving their link, in production, which is
      # the wrong place to fail. deliver: stays a plain callable even now
      # that Monk::Mail exists (docs/adr/0012-minimal-built-in-mailer.md):
      # it's usually a one-line Monk::Mail.deliver, but can be any channel.
      #
      # `link` is usually login_link(token), above. An app may build its
      # own instead, from a trusted origin, never from request headers.
      # `token` is passed through for a deliver: that wants it (an SMS
      # body instead of a link, say); most won't need it.
      def deliver_link(email:, link:, token: nil)
        ensure_configured!

        if config[:deliver]
          config[:deliver].call(email: email, link: link, token: token)
        elsif Monk.env.development?
          log_dev_link(link, subject: email)
        else
          raise MissingAuthDeliveryError,
            "Monk::Auth.configure(deliver:) is not set, and this isn't development -- " \
            "#{email.inspect}'s magic link would never be sent. Configure a deliver: " \
            "callable (wrapping your mailer or provider's API), or call " \
            "Monk::Auth.log_dev_link directly if that's truly intended here."
        end
      end

      # Convenience for an app's own login-request handler: prints a
      # magic link to the dev console (and log/development.log via
      # Monk::Log.info), plus a scannable QR code beneath it if the
      # optional `rqrcode` gem is in the app's own Gemfile -- makes
      # testing the login flow from a second device (another browser, a
      # phone) trivial without a mailer. A no-op outside development,
      # same posture as every other dev-only escape hatch in this
      # framework (docs/history/secure-cookie-dev-http.md). #deliver_link
      # above is what an app should call day to day; this is its
      # development-only fallback and is still fine to call directly.
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

      # Deletes expired login tokens and sessions, and login requests older
      # than login_request_interval; returns how many of each. At most
      # batch_size rows per statement, so a large backlog (the first sweep
      # of an app that never swept) holds no lock for long. Run nightly by
      # Monk::Auth::Sweep (docs/plan-auth-housekeeping.md decision 3).
      # Deliberately not grown onto Model: a `<` comparison is real
      # query-DSL scope for a hygiene task (docs/design/auth-sessions.md).
      def sweep!(batch_size: SWEEP_BATCH_SIZE)
        ensure_configured!
        unless batch_size.is_a?(Integer) && batch_size.positive?
          raise ArgumentError, "batch_size: must be a positive Integer, got #{batch_size.inspect}"
        end

        Monk::Persistence::Pg.checkout(config[:db_name]) do |conn|
          now = Time.now
          {
            login_tokens: delete_in_batches(conn, SWEEP_LOGIN_TOKENS_SQL, [now], batch_size),
            sessions: delete_in_batches(conn, SWEEP_SESSIONS_SQL, [now], batch_size),
            login_requests: delete_in_batches(
              conn, SWEEP_LOGIN_REQUESTS_SQL, [config[:login_request_interval]], batch_size,
            ),
          }
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

      # An absolute path, kept without a trailing slash so login_link
      # adds exactly one before the token.
      def checked_callback_path(path)
        unless path.is_a?(String) && path.start_with?("/")
          raise Monk::InvalidAuthConfigError,
            "Monk::Auth.configure(callback_path:) must be an absolute path like \"/auth/callback\", got #{path.inspect}"
        end

        path.chomp("/").freeze
      end

      # Runs a batched DELETE until one deletes less than a full batch; the
      # batch size is its last parameter.
      def delete_in_batches(conn, sql, params, batch_size)
        total = 0
        loop do
          deleted = conn.exec_params(sql, params + [batch_size]).cmd_tuples
          total += deleted
          return total if deleted < batch_size
        end
      end

      def checked_login_request_interval(seconds)
        unless seconds.is_a?(Integer) && seconds.positive?
          raise Monk::InvalidAuthConfigError,
            "Monk::Auth.configure(login_request_interval:) must be a positive Integer of seconds, got #{seconds.inspect}"
        end

        seconds
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

# Monk::Auth::SendLoginLink, when jobs are loaded too -- either order works
# (lib/monk/jobs.rb ends the same way, docs/adr/0017).
require_relative "auth/send_login_link" if Monk.const_defined?(:Jobs)
require_relative "auth/sweep" if Monk.const_defined?(:Jobs)
