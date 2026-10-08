## live

HTML pushed to open pages over the WebSocket (websocket, above): a route
changes something and calls `Monk::Live.patch`; every page showing it
updates, with no page JavaScript of your own. The layout's
`<%= monk_head %>` loads the browser client, which Monk serves from the gem.

### Try the demo

With `bin/server` and `bin/websocket_server` running, open
http://localhost:9292/demo/live in two tabs and press the button in one:
the other updates by itself. The demo exists in development only. To
remove it, delete `app/routes/demo_live.rb`, `app/views/demo/`, and the
`monk:demo live` lines in `config/live.rb`.

### Before production

`LIVE_WS_URL` defaults to a `/ws` path under `PUBLIC_URL`, with `wss://`
for an `https://` origin: the proxy in front routes `/ws` to
`bin/websocket_server` (docs/guides/deploying.md in the monk repo).

### Check it works

`bundle exec rake test` runs `test/live_test.rb`: an update reaches a socket
subscribed to its topic.
