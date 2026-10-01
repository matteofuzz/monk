require_relative "config/load" # the configs and app/ (config/load.rb)
require_relative "app/app"

run Monk.boot(App) # Boot: freezes the app and serves it
