class App < Monk::Base
  views "app/views"
  layout "layouts/app"
  assets "public"

  get("/") { @title = "App"; render "index" }
  get("/hello") { "hello from monk" }
  get("/api/hello") { json(message: "hello from monk") }
end

# More routes, each file reopening `class App`: the ones Monk modules add
# (monk add), and any of your own. Loaded in name order, before Monk.boot
# freezes the app.
Dir[File.expand_path("routes/*.rb", __dir__)].sort.each { |file| require file }
