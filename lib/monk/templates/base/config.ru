require "monk"

class App < Monk::Base
  get("/hello") { "hello from monk" }
end

run Monk.boot(App)
