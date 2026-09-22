require "monk"
require "monk/auth"
require_relative "persistence"

Monk::Settings.configure do
  # Trusted origin for the magic link your own login route builds (e.g.
  # "#{Monk::Settings[:public_url]}/auth/callback/#{token}") -- never build
  # it from request headers like X-Forwarded-Proto/Host, which any direct
  # client can spoof. Set to your real https:// origin outside development.
  optional :public_url, default: "http://localhost:9292"
end

# Sends the magic link once you have real delivery (email, SMS, ...) --
# a module constant, not a lambda inline in Auth.configure below, since
# self at this file's top level isn't Ractor-shareable (same constraint as
# Monk::Live.authorize blocks). Until this is wired up for real,
# Monk::Auth.deliver_link falls back to Monk::Auth.log_dev_link in
# development and raises everywhere else -- see docs/guides/auth.md.
module AppMailer
  # DELIVER = ->(email:, link:, token:) { YourMailer.magic_link(email, link) }
end

Monk::Auth.configure(
  db_name: :primary,
  secret: ENV.fetch("AUTH_SECRET"),
  login_ttl: 600,          # seconds a login token stays redeemable
  session_ttl: 1_209_600,  # seconds a session stays valid (14 days)
  redirect_allowlist: [],  # paths request_login(redirect_to:) is allowed to target
  secure: !Monk.env.development?, # Secure cookie flag; off in dev so plain-http testing works (Safari drops it)
  # deliver: AppMailer::DELIVER,
)
