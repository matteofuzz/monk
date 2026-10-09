# Routes that push updates to open pages (monk add live).
#
# monk:example live-broadcast -- the route changing the greeting (app/broadcasts/greeting.rb).
# class App
#   post("/greeting") do
#     GreetingBroadcast.update(params[:text].to_s)
#     json(updated: true)
#   end
# end
# monk:end
