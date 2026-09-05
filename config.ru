require "monk"

# Route blocks can't close over mutable state, and a constant holding an
# unfrozen object is unreadable from a worker Ractor -- so the demo's
# route list is deep-frozen up front, the same discipline a real app's
# view data needs.
ROUTES = Ractor.make_shareable([
  ["/hello", "a plain-text route"],
  ["/hits", "a counter in a StateRactor"],
  ["/users/42", "a path param"],
  ["/greet/ada", "JSON from a one-arg route block"],
])

class DemoApp < Monk::Base
  views "views"
  layout "layouts/app"
  assets "public"

  hits = Monk::StateRactor.new(0)
  increment = Ractor.make_shareable(proc { |v| v + 1 })

  get("/") { @title = "Monk"; render "index", routes: ROUTES }
  get("/hello") { "hello from monk" }
  get("/hits") { json(hits: hits.update(&increment)) }
  get("/users/:id") { params[:id] }
  get("/files/*") { params[:splat] }
  get("/greet/:name") { |ctx| json(greeting: "hi #{ctx.params[:name]}") }
  get("/protected") { halt 401, "nope" }
  get("/boom") { raise "unhandled" }
  get("/known-boom") { raise ArgumentError, "bad input" }
  error(ArgumentError) { json(error: "bad input, handled") }
  error(404) { json(error: "not found") }
end

run Monk.boot(DemoApp)
