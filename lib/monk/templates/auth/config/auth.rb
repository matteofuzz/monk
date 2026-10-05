require "monk"
require "monk/auth"
require_relative "persistence"

# config/settings.rb already declares public_url -- the trusted origin for
# the magic link your own login route builds (e.g.
# "#{Monk::Settings[:public_url]}/auth/callback/#{token}"), see its comment
# there and auth.md's "Sending the magic link".

# Sends the magic link by email: AppMailer::MAGIC_LINK, in
# app/mailers/app_mailer.rb. Required here, not left to config/load.rb:
# Monk::Auth.configure checks deliver: right away, and bin/websocket_server
# loads this file without config/load.rb. The mailer only touches
# Monk::Mail when it's called, so that process needs no mail config.
require_relative "../app/mailers/app_mailer"

Monk::Auth.configure(
  db_name: :primary,
  secret: ENV.fetch("AUTH_SECRET"),
  login_ttl: 600,          # seconds a login token stays redeemable
  session_ttl: 1_209_600,  # seconds a session stays valid (14 days)
  redirect_allowlist: [],  # paths request_login(redirect_to:) is allowed to target
  secure: !Monk.env.development?, # Secure cookie flag; off in dev so plain-http testing works (Safari drops it)
  deliver: AppMailer::MAGIC_LINK,
)

# bin/websocket_server checks each socket's session through this pool, so
# it holds 4 connections however many pages are open, instead of one per
# open page. Declaring it opens nothing: only bin/websocket_server starts
# it. See docs/guides/persistence.md, "Pools", in the monk repo.
Monk::Persistence::Pg.pool(:auth, size: 4)
