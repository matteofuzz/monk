class App < Monk::Base
  views "app/views"
  layout "layouts/app"
  assets "public"

  get("/") { @title = "App"; render "index" }
  get("/hello") { "hello from monk" }
  get("/api/hello") { json(message: "hello from monk") }
end
