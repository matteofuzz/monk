require "monk"
require "monk/auth"
require_relative "persistence"

# Magic links are Monk::Auth.login_link(token): config/settings.rb's
# public_url (the trusted origin), then callback_path: below, then the
# token -- see auth.md's "Sending the magic link".

# Sends the magic link by email: AuthMailer::MAGIC_LINK, in
# app/mailers/auth_mailer.rb. Required here, not left to config/load.rb:
# Monk::Auth.configure checks deliver: right away, and bin/websocket_server
# loads this file without config/load.rb. The mailer only touches
# Monk::Mail when it's called, so that process needs no mail config.
require_relative "../app/mailers/auth_mailer"

Monk::Auth.configure(
  db_name: :primary,
  secret: ENV.fetch("AUTH_SECRET"),
  login_ttl: 600,          # seconds a login token stays redeemable
  session_ttl: 1_209_600,  # seconds a session stays valid (14 days)
  redirect_allowlist: [],  # paths request_login(redirect_to:) is allowed to target
  callback_path: "/auth/callback", # your route redeeming a token: GET "#{callback_path}/:token"
  secure: !Monk.env.development?, # Secure cookie flag; off in dev so plain-http testing works (Safari drops it)
  deliver: AuthMailer::MAGIC_LINK,
)

# bin/websocket_server checks each socket's session through this pool, so
# it holds 4 connections however many pages are open, instead of one per
# open page. Declaring it opens nothing: only bin/websocket_server starts
# it. See docs/guides/persistence.md, "Pools", in the monk repo.
Monk::Persistence::Pg.pool(:auth, size: 4)
