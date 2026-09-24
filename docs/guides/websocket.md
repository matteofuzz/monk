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
requires `authenticate: true`) re-runs `Monk::Auth.verify` against the
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

## Cross-process fan-out — `Monk::WebSocket::RedisFanout`

A `Registry` only reaches connections held by its own process. Once a
WebSocket server is scaled to more than one process (or host),
`Monk::WebSocket::RedisFanout` wraps a `Registry` behind the identical
`#register`/`#unregister`/`#count`/`#broadcast` interface, so swapping which
object a connection holds is the only change an app makes:

```ruby
require "monk/websocket/redis_fanout"

REGISTRY = Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: ENV.fetch("REDIS_URL"))
```

`#broadcast` still delivers to this process's own `Registry` directly —
same latency and reliability as a plain `Registry` if Redis is briefly
unavailable — and additionally publishes to Redis so sibling processes'
subscriber Ractors deliver it to their own local connections. Opt-in at the
`require` line: `require "monk/websocket"` alone never loads this, and it
needs the `redis` gem (`--redis`, below, adds it for a scaffolded app).

`Monk::WebSocket::PgFanout` implements the identical interface over Postgres
`LISTEN`/`NOTIFY` instead — for an app that already runs Postgres and would
rather not add Redis as a second dependency (`docs/guides/live.md`'s "Without
Redis" section has the worked example). It caps a single broadcast at just
under 8000 bytes (`PgFanout::MAX_NOTIFY_PAYLOAD_BYTES`, Postgres's own
`NOTIFY` limit) and has no higher-throughput story for many processes/hot
topics — reach for `RedisFanout` instead once either of those matters.
