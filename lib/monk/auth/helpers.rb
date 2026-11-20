require_relative "../context"

module Monk
  module Auth
    # Mixed into Monk::Context (docs/design/auth-sessions.md's "Helpers, not
    # state"): a Context is per-request and never crosses Ractors, so
    # memoizing current_subject on it is exempt from the app's
    # shareability constraints -- nothing here needs Ractor.make_shareable.
    module Helpers
      # With a session cookie, also mends the csrf_token cookie when it
      # doesn't match the session: after AUTH_SECRET changes (a restored
      # backup, a rotated secret) the session still verifies, since it's
      # stored as a plain hash, but the cookie was signed with the old
      # secret, and every require_csrf! route, logout included, would be
      # a 403 until the browser's cookies were cleared.
      def current_subject
        return @current_subject if defined?(@current_subject)
        return @current_subject = Monk::Auth.verify(bearer_token) if bearer_token

        token = session_cookie_token
        session = Monk::Auth.verified_session(token)
        reissue_csrf_cookie(token, session[:expires_at]) if session
        @current_subject = session&.fetch(:subject)
      end

      def require_user!
        current_subject || halt(401)
      end

      # A no-op for Bearer-authenticated requests: a cross-origin attacker
      # page has no channel to set an Authorization header at all, so the
      # CSRF vector only exists for the cookie-authenticated path
      # (docs/design/auth-sessions.md's "CSRF: stateless double-submit").
      # The token comes in the X-CSRF-Token header (fetch) or a csrf_token
      # field (a form, written by #csrf_field). Defence in depth: Monk's
      # cross-origin check already refuses another site's requests.
      def require_csrf!
        return if bearer_token

        cookie_token = session_cookie_token
        provided = header("x-csrf-token") || params[:csrf_token]
        return if cookie_token && provided.is_a?(String) &&
          OpenSSL.secure_compare(Monk::Auth.csrf_token_for(cookie_token), provided)

        # A valid session gets a csrf_token cookie that matches before the
        # 403, so a page that sent a stale one succeeds when it tries again.
        current_subject
        halt(403)
      end

      # The hidden field that require_csrf! reads, for a form posted by a
      # signed-in browser:
      #   <form method="post" action="/logout"><%= csrf_field %>...</form>
      # Empty without a session cookie: there's no token to send.
      def csrf_field
        token = session_cookie_token
        return raw("") unless token

        raw(%(<input type="hidden" name="csrf_token" value="#{h(Monk::Auth.csrf_token_for(token))}">))
      end

      def set_session_cookie(session)
        max_age = [(session[:expires_at] - Time.now).to_i, 0].max
        add_response_cookie("session_token", session[:token], http_only: true, max_age: max_age)
        add_response_cookie("csrf_token", Monk::Auth.csrf_token_for(session[:token]), http_only: false, max_age: max_age)
      end

      def clear_session_cookie
        add_response_cookie("session_token", "", http_only: true, max_age: 0)
        add_response_cookie("csrf_token", "", http_only: false, max_age: 0)
      end

      # Ends the current session: revokes it, whether its token came as a
      # Bearer header or the session cookie, and clears the cookies -- with
      # or without a session to end. On a cookie-authenticated route, call
      # require_csrf! first.
      def log_out!
        token = bearer_token || session_cookie_token
        Monk::Auth.revoke(token) if token
        clear_session_cookie
        nil
      end

      private

      def bearer_token
        auth_header = header("authorization")
        return nil unless auth_header&.start_with?("Bearer ")

        token = auth_header.delete_prefix("Bearer ")
        token.empty? ? nil : token
      end

      def reissue_csrf_cookie(session_token, expires_at)
        expected = Monk::Auth.csrf_token_for(session_token)
        sent = request_cookies["csrf_token"]
        return if sent && OpenSSL.secure_compare(expected, sent)

        max_age = [(expires_at - Time.now).to_i, 0].max
        add_response_cookie("csrf_token", expected, http_only: false, max_age: max_age)
      end

      def add_response_cookie(name, value, http_only:, max_age:)
        add_cookie(name, value, http_only: http_only, max_age: max_age, secure: Monk::Auth.config[:secure])
      end

      def session_cookie_token
        request_cookies["session_token"]
      end
    end
  end
end

Monk::Context.include(Monk::Auth::Helpers)
