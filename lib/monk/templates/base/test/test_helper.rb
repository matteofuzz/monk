ENV["MONK_ENV"] ||= "test"

# The test values the modules this app uses wrote (.env.test), loaded
# before config/settings.rb's .env, which doesn't override them. Only the
# database name and MONK_ENV differ from development, and they're two
# separate settings: MONK_ENV=test alone doesn't change DB_NAME.
env_test = File.expand_path("../.env.test", __dir__)
if File.exist?(env_test)
  require "dotenv"
  Dotenv.load(env_test)
end

require "minitest/autorun"
require_relative "../config/load"
require_relative "../app/app"

# Booted once, as config.ru does: request tests call APP.
APP = Monk.boot(App)
