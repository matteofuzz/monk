require_relative "../context"

module Monk
  module Auth
    # Mixed into Monk::Context (docs/auth-sessions.md's "Helpers, not
    # state"): a Context is per-request and never crosses Ractors, so
    # memoizing current_subject on it is exempt from the app's
    # shareability constraints -- nothing here needs Ractor.make_shareable.
    module Helpers
      def current_subject
        return @current_subject if defined?(@current_subject)

        @current_subject = Monk::Auth.verify(bearer_token || session_cookie_token)
      end

      def require_user!
        current_subject || halt(401)
      end

      # A no-op for Bearer-authenticated requests: a cross-origin attacker
      # page has no channel to set an Authorization header at all, so the
      # CSRF vector only exists for the cookie-authenticated path
      # (docs/auth-sessions.md's "CSRF: stateless double-submit").
      def require_csrf!
        return if bearer_token

        cookie_token = session_cookie_token
        provided = header("x-csrf-token")
        return if cookie_token && provided && OpenSSL.secure_compare(Monk::Auth.csrf_token_for(cookie_token), provided)

        halt(403)
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

      private

      def bearer_token
        auth_header = header("authorization")
        return nil unless auth_header&.start_with?("Bearer ")

        token = auth_header.delete_prefix("Bearer ")
        token.empty? ? nil : token
      end

      def add_response_cookie(name, value, http_only:, max_age:)
        flags = ["Path=/", "Secure", "SameSite=Lax", "Max-Age=#{max_age}"]
        flags << "HttpOnly" if http_only
        headers["set-cookie"] = Array(headers["set-cookie"]) + ["#{name}=#{value}; #{flags.join("; ")}"]
      end

      def request_cookies
        header("cookie").to_s.split(";").each_with_object({}) do |pair, cookies|
          name, value = pair.strip.split("=", 2)
          cookies[name] = value if name
        end
      end

      def session_cookie_token
        request_cookies["session_token"]
      end
    end
  end
end

Monk::Context.include(Monk::Auth::Helpers)
