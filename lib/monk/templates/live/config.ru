require_relative "config/settings"
require_relative "config/live"

class App < Monk::Base
  views "views"
  layout "layouts/app"
  assets "public"

  # State shared across requests lives in a StateRactor; the update block is
  # built here, where self is shareable, not inline in the route.
  hits = Monk::StateRactor.new(0)
  increment = Ractor.make_shareable(proc { |n| n + 1 })

  get("/") { @title = "App"; render "index", hits: hits.value }

  # Change state, then tell every open page that shows it. Monk::Live.patch
  # renders the partial once and pushes it to the "hits" topic's subscribers.
  post("/hit") do
    Monk::Live.patch("hits", to: "#hits", partial: "live/_hits", hits: hits.update(&increment))
    redirect "/"
  end

  get("/hello") { "hello from monk" }
  get("/api/hello") { json(message: "hello from monk") }
end

run Monk.boot(App)
