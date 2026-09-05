require "monk"

class App < Monk::Base
  views "views"
  layout "layouts/app"
  assets "public"

  get("/") { @title = "App"; render "index" }
  get("/hello") { "hello from monk" }
end

run Monk.boot(App)
