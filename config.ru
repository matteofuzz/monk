require_relative "lib/monk"

class DemoApp < Monk::Base
  get("/hello") { "hello from monk" }
  get("/users/:id") { params[:id] }
  get("/files/*") { params[:splat] }
end

run DemoApp
