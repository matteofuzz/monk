# WebSocket — `Monk::WebSocket`

A hand-rolled RFC 6455 server, opt-in (`require "monk/websocket"`),
running as its **own process on its own port** — Kino has no hijack
support, so this never shares a process with your HTTP app
([`design/websocket.md`](../design/websocket.md)). Each connection gets its own dedicated Ractor:

```ruby
require "monk/websocket"

# The handler must be built where self is Ractor-shareable -- a module
# body, not a script's own top level (self there is the main object,
# which isn't shareable) -- same constraint Monk::StateRactor#update has.
module Chat
  REGISTRY = Monk::WebSocket::Registry.new

  HANDLER = proc do |connection|
    connection.subscribe(REGISTRY, :chat)
    loop do
      message = connection.read # nil on disconnect/close -- exits the loop
      break unless message

      REGISTRY.broadcast(:chat, "#{connection.subject}: #{message}")
    end
  end
end

server = Monk::WebSocket::Server.new(
  port: 9293, authenticate: true, allowed_origins: ["https://example.com"],
  ping_interval: 30, reverify_interval: 60,
)
server.run(&Chat::HANDLER)
```

`authenticate: true` reuses `Monk::Auth` unmodified — the same
`Authorization: Bearer` header or `session_token` cookie the HTTP side
accepts, verified before the `101` response is sent; a missing or invalid
credential gets a `401`. `allowed_origins:` guards the cookie path
specifically against Cross-Site WebSocket Hijacking (a Bearer connection
has no `Origin` header to forge). `ping_interval:` (seconds, off by
default) sends a server-initiated ping on that cadence — a spec-compliant
client answers it with a pong automatically, no app code involved either
side, which is what actually defeats an idle reverse-proxy timeout: a
connection that only ever answers a client's own pings stays vulnerable
whenever the client is a browser, since browser JavaScript has no API to
send WS pings at all. `reverify_interval:` (seconds, off by default,
requires `authenticate: true` or `:optional`) re-runs `Monk::Auth.verify` against the
same credential on that cadence and closes the socket the moment it comes
back nil — without it, a session revoked or expired after the handshake
leaves the connection live indefinitely, since `authenticate: true` only
checks the credential once, at connect time. `max_payload_size:` (bytes,
1 MiB by default, **on** by default unlike the other two) rejects a frame
whose declared length exceeds it before ever reading that many bytes off
the wire, and applies the same cap to a fragmented message's reassembled
total — a public endpoint shouldn't trust a claimed length, or let many
small frames add up past it. A reverse proxy in front routes `/ws` to
this process and everything else to Kino, on the **same host** — see
[`deploying.md`](deploying.md) for a worked Caddy/nginx example. Full design and
phase-by-phase build: [`design/websocket.md`](../design/websocket.md) / `docs/history/plan-websocket.md`.

`db_pool:` (a pool name) checks sessions through that
[`Monk::Persistence::Pg` pool](persistence.md#pools) instead of in each
socket's Ractor: the handshake's check, `:optional`'s, and every
`reverify_interval:` check. Without it, each socket's Ractor opens a
Postgres connection on its first check and keeps it while the page stays
open, one connection per open page; it's closed when the socket ends. With it, the server holds only the
pool's: measured, 1,000 open sockets on a pool of 4 held 4 connections.
It requires `authenticate:`, and the pool started before the server
(`Server.new` checks):

```ruby
Monk::Persistence::Pg.start_pools!(:auth)
server = Monk::WebSocket::Server.new(port: 9293, authenticate: :optional, db_pool: :auth)
```

`authenticate:` has three modes:

| Mode | A valid session | No session, or one no longer valid |
|---|---|---|
| `false` (default) | anonymous: identity is never checked | anonymous |
| `true` | its subject | refused, `401` |
| `:optional` | its subject | anonymous (`connection.subject` is `nil`) |

`:optional` is for an app where visitors and logged-in users share pages:
the handler decides what an anonymous connection may do. Under
`Monk::Live` that's the topic rules: deny by default, and a topic is open
to visitors only if its rule says `anonymous: true` (see
[`live.md`](live.md), "Who may subscribe"). A handler with no such rules,
like the chat above, would let anyone in, so keep `true` for it. The
`Origin` check still applies under `:optional`: to a cookie, as under
`true`, and to an anonymous connection that sends an `Origin` (only a
browser does), so another site's page can't open sockets here on its
visitors' behalf. `reverify_interval:` watches only the connections that
have a session; one that loses it is closed, and a browser reconnects as
anonymous. Anonymous sockets cost the server a Ractor each, like any
other, and anyone can open them: an app whose live pages are all private
should keep `true`, which refuses them at the door.

## Stopping and restarting

`server.run` returns on Ctrl-C or `TERM` (what `docker stop` and every
platform send on a deploy): the server stops accepting, and the script
ends with exit 0. Open connections are dropped when the process exits,
**without a close frame**: a client sees an abnormal close (`1006`), the
same as a crash or a network blip.

> **Warning for clients other than `monk_live.js`.** On every deploy or
> restart, expect the socket to drop with no close frame. Reconnect with
> backoff **and jitter** (otherwise every copy of your client reconnects in
> the same instant), and refetch whatever state you show: nothing published
> while you were disconnected is replayed. `monk_live.js` does all three.
> Graceful close frames and draining are an open question
> ([`design/websocket.md`](../design/websocket.md), "Stopping the server").

## Cross-process fan-out — `Monk::WebSocket::RedisFanout`

A `Registry` only reaches connections held by its own process. Once a
WebSocket server is scaled to more than one process (or host),
`Monk::WebSocket::RedisFanout` wraps a `Registry` behind the identical
`#register`/`#unregister`/`#count`/`#broadcast`/`#listen!` interface, so swapping which
object a connection holds is the only change an app makes:

```ruby
require "monk/websocket/redis_fanout"

REGISTRY = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: ENV.fetch("REDIS_URL"))
```

`#broadcast` still delivers to this process's own `Registry` directly —
same latency and reliability as a plain `Registry` if Redis is briefly
unavailable — and additionally publishes to Redis so sibling processes'
subscriber Ractors deliver it to their own local connections.

A fanout only subscribes once `REGISTRY.listen!` is called, once, at boot,
in the process that holds the sockets (the scaffolded `bin/websocket_server`
does it before `server.run`). It returns when the subscription is in
effect, and raises `Monk::WebSocket::ListenError` if Redis can't be
reached. A process that only broadcasts never calls it, so it opens no
subscriber connection. `#register` on a fanout that isn't listening raises
`Monk::WebSocket::NotListeningError`. A plain `Registry` has `#listen!` too,
as a no-op, so the same line works whichever one `REGISTRY` holds. Opt-in at the
`require` line: `require "monk/websocket"` alone never loads this, and it
needs the `redis` gem (`--redis`, below, adds it for a scaffolded app).

`Monk::WebSocket::PgFanout` implements the identical interface over Postgres
`LISTEN`/`NOTIFY` instead — for an app that already runs Postgres and would
rather not add Redis as a second dependency (`docs/guides/live.md`'s "Without
Redis" section has the worked example). It caps a single broadcast at just
under 8000 bytes (`PgFanout::MAX_NOTIFY_PAYLOAD_BYTES`, Postgres's own
`NOTIFY` limit) and has no higher-throughput story for many processes/hot
topics — reach for `RedisFanout` instead once either of those matters.
