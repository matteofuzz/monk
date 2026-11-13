require "monk"
require "monk/presence"
require_relative "persistence"

# Monk::Presence (monk add presence): whether a signed-in person (a
# Monk::Auth subject) has a page open. bin/websocket_server counts its
# sockets and writes them to Postgres; any process reads them. Loaded by
# config/load.rb and by bin/websocket_server. Monk's
# docs/guides/presence.md says how it works.
#
#   Monk::Presence.status(["ann@example.com"])
#   # => {"ann@example.com" => {status: :online, last_seen_at: nil}}
#   Monk::Presence.online?("ann@example.com")
#
# :online is a page open and visible, :away only hidden ones (a phone in a
# pocket), :offline none; last_seen_at is when an offline person was last
# there. grace: seconds after a person's last page closes before they
# read as offline, so a phone changing network or a deploy reconnecting
# every page changes nobody's status.
Monk::Presence.configure(db_name: :primary, grace: 20)

# on_change runs in bin/server (config.ru starts it) each time some
# people's status changes, with all of them at once:
# {subject => {status:, last_seen_at:}}. At most once per change: one
# missed while no bin/server runs isn't sent later, and a Live page
# catches up when it reconnects. Its block must be Ractor-shareable, so
# it's built in a module (self at the top of this file is not).
#
# monk:example presence-dots -- push each change to the pages showing those people (needs live).
# # A page wraps its people in <div <%= live_topic "presence" %>> and shows
# # each with <%= render "presence/_dot", subject: email, status: ..., layout: false %>.
# # One message per 50 changes, not one per person: a burst stays within
# # the WebSocket transport's limits (8 KB a message over Postgres).
# module AppPresence
#   CHANGED = proc do |changes|
#     changes.each_slice(50) do |slice|
#       Monk::Live.batch("presence") do |batch|
#         slice.each do |subject, change|
#           batch.patch(to: AppPresence.dots(subject), partial: "presence/_dot", subject: subject,
#             status: change[:status],)
#         end
#       end
#     end
#   end
#
#   # Every dot of one person on a page, as a CSS selector.
#   def self.dots(subject) = %([data-presence="#{subject.gsub(/["\\]/) { "\\#{it}" }}"])
# end
# Monk::Presence.on_change(&AppPresence::CHANGED)
# # Signed-in people may see everyone's dots: narrow it to what your pages show.
# Monk::Live.authorize("presence", &Monk::Live::ALLOW_ALL)
# monk:end
