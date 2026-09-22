# Loads a local .env file in development, if the app has uncommented the
# dotenv gem in its Gemfile (see the commented-out line there) and added
# a .env file of its own. A missing .env, or the gem not being in the
# bundle at all, is a harmless no-op either way -- production deploys
# get their env vars from the hosting platform directly, not from here.
begin
  require "dotenv/load"
rescue LoadError
end

require "monk"

Monk::Settings.configure do
  # This app's own public origin -- the one trusted source for building an
  # absolute URL back to itself (a magic link, the WebSocket URL a browser
  # should open), instead of request headers like X-Forwarded-Proto/Host,
  # which any direct client can spoof. Declared here, not in config/auth.rb
  # or config/live.rb, since both read it: auth.md's "Sending the magic
  # link" and live.md's `live_ws_url`. Set to your real https:// origin
  # outside development.
  optional :public_url, default: "http://localhost:9292"
end

# Declare more of the app's own settings here, read anywhere via
# Monk::Settings[:key] or, per-request, Context#settings[:key]:
#
# Monk::Settings.configure do
#   required :api_key
#   optional :port, default: "9292"
# end
