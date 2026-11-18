# Web push (monk add push). push.js (loaded by <%= monk_head %>) stores
# each browser's subscription through the first route; the app sends with
# Monk::Push.notify, which enqueues one job per device.
#
# monk:example push-subscribe -- store and forget this browser's subscription.
# # push.js POSTs the browser's subscription here on every page load once
# # notifications are on, and DELETEs it when they're turned off: path: in
# # config/push.rb. A subscription belongs to the session it's made in, so
# # logging out stops that device's notifications.
# class App
#   post("/push/subscription") do
#     require_user!
#     require_csrf!
#     stored = Monk::Push.subscribe(session_token: session_cookie_token, subscription: params,
#       user_agent: header("user-agent"),)
#     halt(401) unless stored
#     json(subscribed: true)
#   rescue Monk::Push::InvalidSubscriptionError => e
#     halt(422, e.message)
#   end
#
#   delete("/push/subscription") do
#     require_csrf!
#     json(unsubscribed: Monk::Push.unsubscribe(params[:endpoint]))
#   end
# end
# monk:end
#
# monk:example push-notify -- a test notification to the signed-in person's devices.
# # Monk::Push.notify(subject, payload) from any route, job or broadcast;
# # sw.js shows { title, body, url, tag }. Returns how many devices.
# class App
#   post("/push/test") do
#     require_user!
#     require_csrf!
#     devices = Monk::Push.notify(current_subject, { title: "Hello", body: "Notifications work.", url: "/" })
#     json(devices: devices)
#   end
# end
# monk:end
