# Whether a signed-in person has a page open (Monk::Presence), counted by
# bin/websocket_server and reacted to in bin/server.
Monk::Generator.define(:presence) do
  summary "Who is online, from the WebSocket's sockets"
  installed_if "config/presence.rb"
  depends_on :auth, :websocket

  copy "config/presence.rb", role: :wiring
  copy "app/views/presence/_dot.erb", role: :view
  copy "test/presence_test.rb", role: :test
  migration "create_presence_tables"

  setup_section "presence/setup.md"
  agents_section "presence/agents.md"
  example "presence-dots", todo: lambda { |installed|
    if installed.include?("live")
      "uncomment to push each change to the pages showing those people"
    else
      "needs live (monk add live) to push each change to open pages; or write your own on_change"
    end
  }
end
