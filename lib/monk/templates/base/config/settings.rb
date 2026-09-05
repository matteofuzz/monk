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

# Declare the app's own settings here, read anywhere via
# Monk::Settings[:key] or, per-request, Context#settings[:key]:
#
# Monk::Settings.configure do
#   required :api_key
#   optional :port, default: "9292"
# end
