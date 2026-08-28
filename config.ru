require_relative "lib/monk"

class DemoApp < Monk::Base
  hits = Monk::StateRactor.new(0)
  increment = Ractor.make_shareable(proc { |v| v + 1 })

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
