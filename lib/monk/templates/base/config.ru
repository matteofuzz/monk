require_relative "config/load" # the configs and app/ (config/load.rb)
require_relative "app/app"

app = Monk.boot(App) # Boot: freezes the app

# With presence (monk add presence) and an on_change in
# config/presence.rb, this process competes to be the one that calls it.
# Here, not in config/load.rb: the tests and bin/console don't react.
Monk::Presence.start_reactor! if defined?(Monk::Presence) && Monk::Presence.configured?

run app # serves it
