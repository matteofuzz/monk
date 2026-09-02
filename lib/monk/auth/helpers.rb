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

        @current_subject = Monk::Auth.verify(bearer_token)
      end

      def require_user!
        current_subject || halt(401)
      end

      private

      def bearer_token
        auth_header = header("authorization")
        return nil unless auth_header&.start_with?("Bearer ")

        token = auth_header.delete_prefix("Bearer ")
        token.empty? ? nil : token
      end
    end
  end
end

Monk::Context.include(Monk::Auth::Helpers)
