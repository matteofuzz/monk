require "monk"
require "monk/auth"
require_relative "persistence"

Monk::Auth.configure(
  db_name: :primary,
  secret: ENV.fetch("AUTH_SECRET"),
  login_ttl: 600,          # seconds a login token stays redeemable
  session_ttl: 1_209_600,  # seconds a session stays valid (14 days)
  redirect_allowlist: [],  # paths request_login(redirect_to:) is allowed to target
)
