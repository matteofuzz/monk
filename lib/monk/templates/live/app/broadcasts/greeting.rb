# What this app pushes to open pages (monk add live).
#
# monk:example live-broadcast -- a greeting that changes in every open page at once.
# # A page shows it in an element subscribed to the topic (and a rule in
# # config/live.rb lets pages subscribe to "greeting"):
# #   <p <%= live_topic "greeting" %>><%= render "live/_greeting", text: "Hello", layout: false %></p>
# # The route that changes it is in app/routes/live.rb.
# module GreetingBroadcast
#   def self.update(text)
#     Monk::Live.patch("greeting", to: "#greeting", partial: "live/_greeting", text: text)
#   end
# end
# monk:end
