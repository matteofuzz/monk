# WebSocket — `Monk::WebSocket`

A hand-rolled RFC 6455 server, opt-in (`require "monk/websocket"`),
running as its **own process on its own port** — Kino has no hijack
support, so this never shares a process with your HTTP app
([`design/websocket.md`](../design/websocket.md)). Each connection gets
its own dedicated Ractor:

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
  ping_interval: 25, reverify_interval: 60,
)
server.run(&Chat::HANDLER)
```

| Option | Default | What it does |
|---|---|---|
| `authenticate:` | `false` | `true` checks the same `Authorization: Bearer` header or `session_token` cookie as the HTTP side, with `Monk::Auth`, before the `101`; a missing or invalid one gets a `401`. `:optional` lets visitors in anonymously. The three modes are below. |
| `allowed_origins:` | none: no check | The `Origin`s a browser socket may come from, against Cross-Site WebSocket Hijacking (a Bearer connection has no `Origin` to forge). The scaffold allows `PUBLIC_URL` and `WS_ALLOWED_ORIGINS`. |
| `ping_interval:` | off | Seconds between server pings, and closes a connection silent for two intervals. At least 5. |
| `reverify_interval:` | off | Seconds between new checks of the session; the socket is closed once it's revoked or expired. Needs `authenticate:`. |
| `max_payload_size:` | 1 MiB | The largest frame, and the largest message once its fragments are put together; checked before the bytes are read. |
| `max_handshakes:` | 128 | Connections in their handshake at once (the upgrade and the session check). At the cap the server stops accepting, and connects wait in the kernel's backlog. |
| `handshake_timeout:` | 10 s | A handshake not over by then, the session check included, is dropped. A request head past 16 KiB gets a `431`. |
| `reuse_port:` | `false` | Several processes on one port ([Several processes](#several-processes)). |
| `db_pool:` | none | Checks sessions through a pool (below). |

**Why the server pings.** A browser can't send WebSocket pings, so
without them a quiet page is cut by the proxy's idle timeout (nginx's
60 s, Cloudflare's 100 s); any client answers a ping with a pong, with no
code on either side. The same pings find a peer that vanished without
closing (a phone that changed network, a laptop that went to sleep):
nothing from it, not even a pong, for two intervals, and it's closed.
Without pings the kernel holds such a socket, and everything subscribed
through it, for about 15 minutes on Linux, or forever. Any frame from the
client counts, so a client that answers is never closed. The minimum of
5 s (`Server::MIN_PING_INTERVAL`) is because reads stall during a GC
pause, and a timeout near that would close healthy sockets in bulk. The
scaffolded `bin/websocket_server` uses 25 s: a vanished peer is closed
after 50 s.

**Why `reverify_interval:`.** `authenticate:` checks the session once, at
connect time; without a recheck, a session revoked or expired later
leaves its socket open.

**Why `max_handshakes:`.** After a restart every page reconnects at once;
with the cap, a burst past what the process can check queues instead of
timing out all together.

A reverse proxy in front routes `/ws` to this process and everything else
to the HTTP app, on the **same host**: `monk add deploy` writes that
Caddyfile, and [`deploying.md`](deploying.md) has it for other setups.
The design is in [`design/websocket.md`](../design/websocket.md).

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

In either mode, a check that can't answer (the pool full or timed out,
the database down) refuses the connection with `503` and one line on
stderr; under `:optional` it isn't let in as anonymous, which would
quietly sign the user out of their topics. A client without an `Origin`
(not a browser) also gets `Retry-After`. A browser can't read a failed
handshake's status, so it retries on `monk_live.js`'s own backoff.

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

## In a Monk app: `monk add websocket`

`monk add websocket --transport=postgres|redis` sets all of this up
([`scaffolding.md`](scaffolding.md)):

- **`config/websocket.rb`** builds the app's one registry,
  `AppWebSocket::REGISTRY`, over the transport: a `PgFanout` publishing
  through the `:notify` pool (size 1, one connection per process, on the
  `:primary` database), or a `RedisFanout` at `Monk::Settings[:redis_url]`.
  Every process loads it; `bin/server` and `bin/jobs` only publish through
  it. `AppWebSocket::TRANSPORT` says which. `AppWebSocket.start!` opens
  the transport (starts the `:notify` pool; nothing with Redis):
  `config/load.rb` calls it at the end, so every process that loads the
  app can publish, and `bin/websocket_server` calls it too.
- **`bin/websocket_server`** loads it, plus `config/auth.rb` and
  `config/live.rb` if the app has them, and runs Live's handler with live,
  or else the app's `AppSockets::HANDLER` from `app/sockets/` (the
  `websocket-chat` example there is the chat above). With neither, it says
  so and exits. It's the only process that calls `listen!`. With auth it
  authenticates sockets, through the `:auth` pool: `:optional` with live,
  whose rules decide what visitors get, and `true` otherwise.
  With presence (`monk add presence`), it also loads `config/presence.rb`
  and counts the signed-in sockets in Postgres, through a connection of
  its own ([`presence.md`](presence.md)); on `TERM` its people keep their
  status for the grace while their pages reconnect elsewhere.
- **`WS_PORT`** (9293) and **`WS_ALLOWED_ORIGINS`** (origins allowed
  besides `PUBLIC_URL`, which always is; comma-separated) configure it, and **`WS_PROCESSES`** (1) how many server processes it
  runs on that port ([Several processes](#several-processes)).
- **GC settings**: `bin/websocket_server` keeps Ruby's heap 60–90% free
  (`RUBY_GC_HEAP_FREE_SLOTS_MIN_RATIO=0.6`, `_GOAL_RATIO=0.8`,
  `_MAX_RATIO=0.9`, `Monk::Bin::WEBSOCKET_GC_ENV`). Ruby reads these only
  at boot, so the script starts itself again with the ones the
  environment doesn't set; a value you set wins. On Ruby 4.0 each new
  connection's Ractor takes a page of the heap, a GC runs once the free
  pages are gone, and every GC stops and marks every open socket. At 15K
  sockets held, these run 6–30× fewer GCs, for ~30% more memory
  (`docs/history/plan-ws-connect-ceiling.md`). On 4.1 they were measured to
  change nothing.

**Switching transports** is three steps:

1. If the other one isn't installed, add it: `monk add redis` or
   `monk add postgres`.
2. Replace `config/websocket.rb` with Monk's version for the other
   transport, then carry over anything you changed in it:
   `monk help websocket --file config/websocket.rb --transport=redis > config/websocket.rb`
   (or `--transport=postgres`).
3. Restart `bin/server`, `bin/websocket_server` and `bin/jobs`.

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

## Several processes

One process holding many sockets is limited by GC: on Ruby 4.0 every GC
stops and marks every open socket, so the connects a second it can take
fall as the sockets it holds grow, about **k / held**. Measured on 4 cores
with Live and the GC settings above, k is 4–5 million: ~800 connects/s at
5K sockets held, ~300/s at 15K, ~180/s at 25K. That matters most after a
restart, when every page reconnects at once: refilling n sockets takes
at least n² / 2k seconds, ~70 s for 25K.

`WS_PROCESSES=K` runs K server processes on `WS_PORT`
(`Server.new(reuse_port: true)`, `SO_REUSEPORT`); on Linux the kernel
spreads connects across them. Each has its own heap and its own GC
pauses over its share of the sockets, so K processes take about **K² × k
/ held** connects a second in all: 2 processes at 25K, ~700/s; 4, ~2,900/s.

- **When**: past ~5K sockets in one process, or when a restart's
  reconnect wave has to be back within seconds. Up to one process a
  core; past that they share cores, and the gain stops.
- **What it costs**: each process holds its own Postgres connections:
  `:auth`'s 4, plus `LISTEN` and `:notify`'s with the Postgres
  transport. Count K times that against `max_connections`.
- **Broadcasts** reach every process through the transport, as they
  already do between `bin/server` and `bin/websocket_server`. With a
  plain in-process `Registry` (no fanout), each process would only reach
  its own sockets.
- **Stopping**: `bin/websocket_server` starts K copies of itself and
  waits on them. `TERM` or Ctrl-C reaches all of them, and it exits 0
  once they have. If one ends on its own (a crash, a service down at
  boot), it stops the others and exits with that one's status, so
  whatever restarts it restarts them all.
- **Containers**: `WS_PROCESSES` is for one host or container. Replicas
  of the WebSocket service (Compose, Kubernetes, a platform's instance
  count) each have their own network and port, so they don't need it:
  the proxy in front spreads connects across them. Each replica is then
  a process with its own heap, the same gain.
- **On macOS**, `SO_REUSEPORT` lets the processes share the port but
  doesn't spread connects evenly; it's for Linux.

The k above is from a Mac running Linux in Docker; the benchmark's VM
will restate it.

## Cross-process fan-out — `Monk::WebSocket::RedisFanout`

A `Registry` only reaches connections held by its own process. Once a
WebSocket server is scaled to more than one process (or host),
`Monk::WebSocket::RedisFanout` wraps a `Registry` behind the identical
`#register`/`#unregister`/`#register_many`/`#unregister_many`/`#count`/`#broadcast`/`#listen!`
interface (the `_many` pair takes an Array of keys in one ask, which is how
`Monk::Live` subscribes a page's topics), so swapping which
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
subscriber connection. `#register` (or `#register_many`) on a fanout that isn't listening raises
`Monk::WebSocket::NotListeningError`. A plain `Registry` has `#listen!` too,
as a no-op, so the same line works whichever one `REGISTRY` holds. Opt-in at the
`require` line: `require "monk/websocket"` alone never loads this, and it
needs the `redis` gem (`monk add redis` adds it to an app).

`Monk::WebSocket::PgFanout` implements the identical interface over Postgres
`LISTEN`/`NOTIFY` instead — for an app that already runs Postgres and would
rather not add Redis as a second dependency (`docs/guides/live.md`'s "Without
Redis" section has the worked example). It caps a single broadcast at just
under 8000 bytes (`PgFanout::MAX_NOTIFY_PAYLOAD_BYTES`, Postgres's own
`NOTIFY` limit) and has no higher-throughput story for many processes/hot
topics — reach for `RedisFanout` instead once either of those matters.
