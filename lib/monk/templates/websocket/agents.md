## websocket

**Where:** `config/websocket.rb` (`AppWebSocket::REGISTRY`, over the app's
transport: `AppWebSocket::TRANSPORT`), `bin/websocket_server` (the socket
process), `app/sockets/` (handlers, when the app doesn't use live).

**Main calls:** `AppWebSocket::REGISTRY.broadcast(topic, payload)` from any
process. In a handler, `proc { |connection| ... }`: `connection.read`,
`connection.subscribe(AppWebSocket::REGISTRY, topic)`,
`connection.subject` (the user, with auth). The server runs
`AppSockets::HANDLER`, or live's.

**Test:** `test/websocket_test.rb` sends a broadcast across two registries
over the transport.

**Pitfalls:**
- Handlers run in each connection's own Ractor: build them in a module
  body, never at a file's top level.
- Only `bin/websocket_server` calls `listen!`; every other process only
  publishes.
- With Postgres, a broadcast is capped at just under 8000 bytes (NOTIFY).
- `WS_ALLOWED_ORIGINS` must list your pages' origins.
- Switching transports is three steps in SETUP.md, websocket.

**Examples:** `websocket-chat` in `app/sockets/chat.rb`.
