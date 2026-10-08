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

`bundle exec rake test` runs `test/websocket_test.rb`: a broadcast crosses
from one registry to another over the transport.
