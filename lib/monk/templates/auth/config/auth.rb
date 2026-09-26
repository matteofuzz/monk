require "monk"
require "monk/auth"
require_relative "persistence"

# config/settings.rb already declares public_url -- the trusted origin for
# the magic link your own login route builds (e.g.
# "#{Monk::Settings[:public_url]}/auth/callback/#{token}"), see its comment
# there and auth.md's "Sending the magic link".

# Sends the magic link by email, through Monk::Mail (config/mail.rb, which
# config.ru requires) -- a module constant, not a lambda inline in
# Auth.configure below, since self at this file's top level isn't
# Ractor-shareable (same constraint as Monk::Live.authorize blocks). The
# HTML part is views/mail/magic_link.erb. Swap the body for SMS or any
# other channel; see docs/guides/auth.md.
module AppMailer
  DELIVER = lambda do |email:, link:, token:|
    # Development only (a no-op elsewhere): the link on the console, plus a
    # QR code for a phone if rqrcode is in the Gemfile.
    Monk::Auth.log_dev_link(link, subject: email)
    Monk::Mail.deliver(
      to: email,
      subject: "Your login link",
      text: "Here's your login link:\n\n#{link}\n\nIf you didn't ask for it, you can ignore this email.",
      html: Monk::Mail.render("mail/magic_link", link: link),
    )
  end
end

Monk::Auth.configure(
  db_name: :primary,
  secret: ENV.fetch("AUTH_SECRET"),
  login_ttl: 600,          # seconds a login token stays redeemable
  session_ttl: 1_209_600,  # seconds a session stays valid (14 days)
  redirect_allowlist: [],  # paths request_login(redirect_to:) is allowed to target
  secure: !Monk.env.development?, # Secure cookie flag; off in dev so plain-http testing works (Safari drops it)
  deliver: AppMailer::DELIVER,
)
