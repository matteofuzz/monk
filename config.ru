require_relative "lib/monk"

class DemoApp < Monk::Base
  get("/hello") { "hello from monk" }
  get("/users/:id") { params[:id] }
  get("/files/*") { params[:splat] }
  get("/greet/:name") { |ctx| json(greeting: "hi #{ctx.params[:name]}") }
  get("/protected") { halt 401, "nope" }
end

run DemoApp
