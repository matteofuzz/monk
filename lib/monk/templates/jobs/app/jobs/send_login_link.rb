# Sends a magic link from bin/jobs instead of the login request. The token
# is created here, right before it's sent, so the raw token is never
# stored anywhere -- not even in the job queue, which a plain
# Monk::Mail.deliver_later of the link would do (Monk's
# docs/adr/0014-mail-from-jobs-and-login-links-created-in-the-job.md).
# Enqueue it from your login route, after your own per-email rate limit
# and with a redirect_to already checked against redirect_allowlist:
#
#   post("/auth/request") do
#     SendLoginLink.enqueue(params[:email])
#     json(sent: true)
#   end
class SendLoginLink < Monk::Job
  queue "mailers"
  # About 50 seconds of retries: a login email minutes late, after the
  # user has likely asked for another, is worse than none.
  max_attempts 3
  never_retry Monk::InvalidRedirectError

  def self.perform(email, redirect_to = nil)
    token = Monk::Auth.request_login(email, redirect_to: redirect_to)
    # Your callback route; config/settings.rb's public_url is the origin.
    link = "#{Monk::Settings[:public_url]}/auth/callback/#{token}"
    # Calls config/auth.rb's deliver: (AppMailer::MAGIC_LINK) -- a
    # synchronous send, here in the job.
    Monk::Auth.deliver_link(email: email, link: link, token: token)
  end
end
