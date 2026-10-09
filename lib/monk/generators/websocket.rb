# The WebSocket server process, over a transport between processes:
# Postgres or Redis.
Monk::Generator.define(:websocket) do
  summary "WebSocket server process"
  installed_if "config/websocket.rb"
  option :transport, values: %w[postgres redis], dependency: true,
    describe: { postgres: "LISTEN/NOTIFY, nothing else to run; 8 KB per broadcast",
                redis: "no size limit; Redis must be running", }

  copy "config/websocket.rb", role: :wiring,
    from: ->(options) { "websocket/config/websocket_#{options[:transport]}.rb" }
  copy "bin/websocket_server", role: :wiring, executable: true
  copy "app/sockets/chat.rb", role: :example
  copy "test/websocket_test.rb", role: :test

  env :example, { "WS_PORT" => "9293" }
  env :example, { "WS_ALLOWED_ORIGINS" => "https://example.com" }, commented: true

  setup_section "websocket/setup.md"
  agents_section "websocket/agents.md"
  set_before_production "WS_ALLOWED_ORIGINS", "defaults to PUBLIC_URL; list every origin your pages use"
  next_step "bin/websocket_server", note: "beside bin/server"
  example "websocket-chat", todo: "uncomment for one chat room, or write your own handler in app/sockets/"
end
