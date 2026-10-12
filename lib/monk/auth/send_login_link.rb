# Monk::Auth::SendLoginLink. Loaded at the end of whichever of monk/auth
# and monk/jobs is required second, once both are defined
# (docs/adr/0017), so it requires neither itself.

module Monk
  module Auth
    # Sends a magic link from bin/jobs instead of the login request. The
    # token is created here, right before it's sent, so the raw token is
    # never stored anywhere -- not even in the job queue, which pointing
    # deliver: at Monk::Mail.deliver_later would do
    # (docs/adr/0014-mail-from-jobs-and-login-links-created-in-the-job.md).
    # Enqueue it from the app's login route, after its own per-email rate
    # limit:
    #
    #   post("/auth/request") do
    #     Monk::Auth::SendLoginLink.enqueue(params[:email])
    #     json(sent: true)
    #   end
    #
    # The link is Monk::Auth.login_link (public_url + callback_path:), and
    # it's sent through configure's deliver:, synchronously, in the job.
    # Subclass it to change the queue or the retries.
    class SendLoginLink < Monk::Job
      queue "mailers"
      # About 50 seconds of retries: a login email minutes late, after the
      # user has likely asked for another, is worse than none.
      max_attempts 3
      never_retry Monk::InvalidRedirectError

      def self.perform(email, redirect_to = nil)
        token = Monk::Auth.request_login(email, redirect_to: redirect_to)
        Monk::Auth.deliver_link(email: email, link: Monk::Auth.login_link(token), token: token)
      end
    end
  end
end
