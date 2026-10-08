# Server-pushed HTML updates (Monk::Live), over the app's WebSocket.
Monk::Generator.define(:live) do
  summary "Server-pushed HTML updates"
  installed_if "config/live.rb"
  depends_on :websocket
  option :demo, values: %w[on off], default: "on"

  demo = ->(options) { options[:demo] == "on" }
  copy "config/live.rb", role: :wiring,
    from: ->(options) { demo.call(options) ? "live/config/live_with_demo.rb" : "live/config/live_without_demo.rb" }
  copy "app/broadcasts/greeting.rb", "app/routes/live.rb", role: :example
  copy "app/views/live/_greeting.erb", role: :view
  copy "app/routes/demo_live.rb", "app/views/demo/live.erb", "app/views/demo/_hits.erb", role: :demo, if: demo
  copy "test/live_test.rb", role: :test

  setup_section "live/setup.md"
  agents_section "live/agents.md"
  set_before_production "LIVE_WS_URL", "defaults to /ws under PUBLIC_URL (wss:// for https)"
  next_step "open http://localhost:9292/demo/live in two tabs, press +1", if: demo
  example "live-rule", todo: "uncomment and adapt: nothing can be subscribed to until a rule allows it"
  example "live-broadcast", todo: "uncomment, add a rule for its topic, and put the live_topic element in a page"
  closing lambda { |options|
    "Remove the demo when done: app/routes/demo_live.rb, app/views/demo/, and its lines in config/live.rb." if
      demo.call(options)
  }
end
