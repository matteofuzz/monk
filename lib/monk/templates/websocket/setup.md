## websocket

`bin/websocket_server` holds the browsers' WebSocket connections, on :9293
(`WS_PORT`), next to `bin/server`. They're separate processes, so a
broadcast travels between them over this app's transport, chosen when the
module was added: `config/websocket.rb` says which.

### Run it

```bash
bin/websocket_server
```

It serves Monk::Live (`monk add live`) or, without it, the handler in
`app/sockets/` (the `websocket-chat` example). With neither, it says so and
exits. In production it's one more process from the same image, with
`bin/websocket_server` as its command.

`WS_ALLOWED_ORIGINS` (default: `PUBLIC_URL`) must list every origin your
pages are served from, or browsers' sockets are refused. Behind TLS, pages
connect with `wss://`.

### Switching transports

1. If the other one isn't installed, add it: `monk add redis` or
   `monk add postgres`.
2. In `config/websocket.rb`, swap the fanout: `Monk::WebSocket::RedisFanout`
   with `redis_url: Monk::Settings[:redis_url]` (and `require_relative
   "redis"`), or `Monk::WebSocket::PgFanout` with
   `pg_opts: Monk::Persistence::Pg.connection_options(:primary)` (and
   `require_relative "persistence"`).
3. Restart `bin/server`, `bin/websocket_server` and `bin/jobs`.

### Check it works

1. `bundle exec rake test` runs `test/websocket_test.rb`: a broadcast
   crosses from one registry to another over the transport.
2. By hand, without live: uncomment the `websocket-chat` block in
   `app/sockets/chat.rb` and start `bin/websocket_server` next to
   `bin/server`. Open http://localhost:9292 in two tabs, and in each
   browser console:

   ```js
   ws = new WebSocket("ws://localhost:9293")
   ws.onmessage = (event) => console.log(event.data)
   ```

   `ws.send("hi")` in one tab logs `guest: hi` in both. With auth, the
   server lets only logged-in sockets in: log in first (auth, above), and
   the message carries your email. With live, `bin/websocket_server` runs
   live's handler instead: live, below.
