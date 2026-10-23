# monk:demo live -- Monk::Live's demo, development only: a counter whose
# open tabs update together. Open http://localhost:9292/demo/live in two
# tabs and press the button in one. To remove it, delete this file,
# app/views/demo/, and the `monk:demo live` lines in config/live.rb.
if Monk.env.development?
  class App
    # State shared across requests lives in a StateRactor; the update block
    # is built here, where self is shareable, not inline in the route.
    demo_hits = Monk::StateRactor.new(0)
    demo_increment = Ractor.make_shareable(proc { |n| n + 1 })

    get("/demo/live") { @title = "Monk::Live demo"; render "demo/live", hits: demo_hits.value }

    # Change state, then tell every open page that shows it. Monk::Live.patch
    # renders the partial once and pushes it to the topic's subscribers.
    post("/demo/live/hit") do
      Monk::Live.patch("demo:hits", to: "#hits", partial: "demo/_hits", hits: demo_hits.update(&demo_increment))
      redirect "/demo/live"
    end
  end
end
