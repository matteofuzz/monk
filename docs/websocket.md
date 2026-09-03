# WebSocket support, as a process separate from Kino

Status: design exploration, 2026-09-01 — two spikes ran the same day.
**Phase 0**: neither off-the-shelf WebSocket gem tried survives a real,
separately-spawned Ractor, for two different, gem-specific reasons (see
"Phase 0 result"). **End-to-end spike**: the hand-rolled alternative that
finding pointed to — a real `TCPServer`, sockets moved into dedicated
per-connection Ractors, hand-rolled RFC 6455 — works correctly, including
true concurrency and isolated per-connection failure (see "End-to-end
spike"). Implementation plan: `PLAN-WEBSOCKET.md`. No code lives in this
repo yet, no ADR yet (the "own process, not in-Kino" call is the one most
likely to want one). `NOTES-V2.md` lists "WebSocket support, with session
persistence" as a v2 candidate; this doc is the first design pass at it.
The identity/token-carrying question this doc originally left open for
Phase 5 is now resolved as part of the same 2026-09-01 pass that finalized
`docs/auth-sessions.md` across all three transports — see "Identity
crosses the process boundary the same way it crosses Ractors" below.

## Why a separate process, not a Kino feature

A prior session established that Kino doesn't support WebSocket and has no
plan to. This session confirmed *why*, empirically, rather than treating
that as a fixed fact to route around blindly — the same "verify, don't
assume" posture `docs/persistence-ractor-connections.md` took with Sequel.

Two live spikes, 2026-09-01, against a real `bundle exec kino` (Ruby 4.0.6,
Kino 0.5.0), using a throwaway `config.ru` outside this repo:

1. **`rack.hijack` env keys.** A Rack app inspected
   `env["rack.hijack?"]` / `env["rack.hijack"]` on a real request. Both keys
   are **entirely absent** from the env hash Kino builds — not `false`,
   missing. Matches Kino's own README: "Full hijack is left out on purpose;
   it is optional in Rack 3."
2. **The one channel Kino *does* expose, tried as a workaround.** Kino
   supports Rack 3's callable/full-duplex response body (for SSE-style
   bidirectional streaming within an ordinary HTTP response). Tried
   returning `101 Switching Protocols` with a callable body writing raw
   bytes after the status line, in case the connection could be repurposed
   post-Upgrade. Kino sent the `101` status and headers correctly, then the
   connection died before any body bytes arrived (`curl`: "empty reply from
   server", exit 52). `101` responses have no body semantics in HTTP —
   Kino's Hyper-based engine doesn't treat a post-`101` connection as a raw
   byte pipe, and there's no reason it should, since nothing in Rack 3 asks
   it to.

**Conclusion: this is architecturally excluded, not merely unimplemented.**
Kino's Rust/Tokio core keeps the raw socket entirely on its side of the
Ruby↔Rust FFI boundary (`lib/kino/worker.rb`'s `serve` only ever receives a
`kino.request` handle, never a socket). No Rack-level trick from inside a
Kino-served app — hijack, `Upgrade`, or otherwise — can get WebSocket framing
control. That's a stronger finding than "no roadmap for it," and it means
the honest design doesn't wait on Kino at all: it routes around Kino
entirely, the same way ADR 0001 already treats Kino as *a* reference server
rather than a dependency to special-case.

## Consequence: WebSocket lives in its own process

The shape: Kino keeps serving the normal HTTP Rack app, unchanged, on its
own port. A second, small process owns a plain `TCPServer` on a separate
port, does the WebSocket handshake (parse the `HTTP/1.1 Upgrade` request,
compute `Sec-WebSocket-Accept` from the client's `Sec-WebSocket-Key` per
RFC 6455) and frame parsing itself, and holds connections open for as long
as clients keep them open. A reverse proxy in front (nginx, Caddy, or
whatever the host already provides — Render and Fly both support routing
by path/port) sends `/ws` to the WebSocket process and everything else to
Kino, **on the same host as the HTTP process** — recommended over a
dedicated subdomain, since "Identity crosses the process boundary" below
depends on that path-based, same-host routing for the browser session
cookie to reach the WS handshake with no extra configuration. A subdomain
still works, but only if the session cookie is explicitly given
`Domain=<shared parent domain>`, which is one more thing that has to be
kept in sync between the HTTP and WS processes' configuration.

This is not a novel pattern — it's the same shape as Rails + ActionCable +
Puma, so existing ops knowledge and reverse-proxy config for that pairing
transfers directly. It also fully sidesteps the finding above: Monk never
needs Kino to grow hijack support, because the WebSocket process never asks
Kino for a socket in the first place.

## Connection lifecycle: one Ractor per connection

Each accepted WebSocket connection gets its own dedicated `Ractor`, the same
trick `StateRactor` already uses (`docs/ractor.md`): the mutable thing — the
live `TCPSocket`, its read buffer, frame-assembly state — stays invisible
inside one Ractor for as long as the connection is open. What crosses to
anything that needs to push a message to that connection is a frozen
handle: a `Ractor::Port` the connection Ractor listens on, not the socket
itself. Sending a message becomes the same synchronous-or-fire-and-forget
"ask" shape `StateRactor#update` already establishes — no new communication
primitive, just applied to a socket instead of a value.

This also isolates failure the right way: one connection's Ractor dying
(client disconnect, a bad frame) doesn't touch any other connection's
Ractor or the accept loop.

## The fan-out problem

A single connection push is solved by the paragraph above. Broadcasting —
"send this to every connection subscribed to X" — is a registry problem
layered on top, at two different scopes:

- **Within one WebSocket process.** A registry Ractor holds the live set of
  connection `Ractor::Port`s (or a `Hash` keyed by subject/channel), and
  broadcast means iterating that set and sending to each port. This is the
  same shape as the "pool of connection-owning Ractors" idea explored (and
  superseded, for the DB case) in `docs/persistence-ractor-connections.md`
  — a dispatcher Ractor holding handles to N worker Ractors — just applied
  to sockets instead of Postgres connections, and here it's the plan, not a
  superseded draft, because unlike a DB connection a socket has nowhere
  else to be pooled.
- **Across processes.** Needed the moment either the WebSocket process is
  horizontally scaled, or Kino's HTTP workers need to push a WS message
  triggered by an ordinary HTTP request (e.g. `POST /orders` should notify
  WS clients watching that order). In-memory registries don't reach across
  a process boundary, so this needs an external transport: Postgres
  `LISTEN`/`NOTIFY` (no new infrastructure — `Monk::Persistence::Pg` is
  already in the repo) or Redis pub/sub if `LISTEN`/`NOTIFY`'s constraints
  (below) rule it out. Not decided — see open questions.

## Identity crosses the process boundary the same way it crosses Ractors

The WebSocket handshake starts as a plain HTTP request, before the
connection upgrades — so it can carry whatever `Authorization: Bearer` or
cookie `docs/auth-sessions.md` designs. Verifying it works identically in
the WebSocket process, because that design is already DB-backed
(`Monk::Persistence::Pg::Model`), not in-Ractor or in-Kino-process state:
the WebSocket process just needs its own `Monk::Persistence.register` call
against the same database, and `Monk::Auth.verify` runs the same way there
as it does inside a Kino worker. Nothing about crossing a process boundary
is special-cased — it's the same reason `NOTES-V2.md` already pairs
"WebSocket support" with "session persistence" as one candidate: a
connection that can't identify its subject isn't useful for most of what
WebSocket gets reached for, and a DB-backed session (not in-memory state)
is what makes identity checks work the same way from a second, independent
process.

**How the token reaches the handshake is now resolved**, not left to
Phase 5 as this doc originally had it. Full reasoning lives in
`docs/auth-sessions.md`'s "The WebSocket case" (finalized 2026-09-01); the
conclusion: a browser-originated connection needs no new carrier at all —
cookies aren't port-scoped, so the session cookie set by the HTTP process
rides along on the WS handshake automatically, *as long as the reverse
proxy in front routes both processes on the same host* (path-based `/ws`
routing, as recommended above, not a separate subdomain unless the cookie
is explicitly given `Domain=` the shared parent domain). A non-browser WS
client sets `Authorization: Bearer` directly on the handshake request —
only the browser's own `WebSocket` JS API is header-restricted, not the
protocol. The one thing this *doesn't* resolve for free: a
cookie-authenticated handshake is forgeable cross-origin the same way a
CSRF'd form post is (Cross-Site WebSocket Hijacking), and neither
`SameSite` nor the HTTP-side CSRF double-submit check reaches a WS
handshake — the WS process must validate the `Origin` header against an
explicit allowlist on every handshake, rejecting before `Monk::Auth.verify`
ever runs. See the companion doc for why `SameSite` specifically can't be
relied on here.

## Phase 0 result: neither off-the-shelf WebSocket gem survives a real Ractor (2026-09-01)

Ran against a real, separately-spawned `Ractor.new` (Ruby 4.0.6, throwaway
scripts, not committed). Resolves open question 1 below — the recommendation
this doc previously carried ("pure Ruby means it should work with zero
friction") **did not hold up**, for two entirely different, gem-specific
reasons. Consistent with this project's standing lesson from the Sequel
spike: pure-Ruby-vs-C-extension is not the only axis that predicts
Ractor-safety, and neither is safe to assume from the outside.

**`websocket` (1.2.11), pure Ruby, zero C extensions — fails unconditionally.**
Every core entry point (`Handshake::Server#<<`, `Frame::Incoming#next`,
`Frame::Outgoing#to_s`) is implemented via a `rescue_method` helper
(`lib/websocket/exception_handler.rb`) that wraps the real method using
`define_method` with an ordinary block. A method defined this way is only
ever callable from the Ractor that defined it — calling it from any other
Ractor raises `RuntimeError: defined with an un-shareable Proc in a
different Ractor`. Verified this is **not a load-order problem**: fully
loading and exercising `Handshake::Server` in the main Ractor first, then
calling the exact same methods from a worker Ractor, fails identically. A
follow-up, gem-independent spike confirmed this is a general Ruby 4 Ractor
rule, not specific to this gem — see the new note in `docs/ractor.md` — and
that it *is* fixable in principle (`Ractor.make_shareable` the block before
`define_method`), but only by patching the gem's internals, not from
calling code.

**`websocket-driver` (0.7.7) — fails for an unrelated, second reason.** Its
optional native masking extension (`websocket_mask.bundle`, used to unmask
client frames — mandatory for a server per RFC 6455) compiled successfully
on install and loads in preference to the pure-Ruby fallback
(`lib/websocket/driver.rb`'s own `require 'websocket_mask'` /
`rescue LoadError; require 'websocket/mask'`). Calling it from a worker
Ractor raises `Ractor::UnsafeError: ractor unsafe method called from not
main ractor` — the extension was never flagged `rb_ext_ractor_safe` by its
maintainers, the same category of failure `sqlite3-ruby` hit in the
persistence spike. Forcing the pure-Ruby mask fallback would dodge this one
failure, but `lib/websocket/driver/server.rb` uses the identical
`define_method`-with-a-block delegator pattern the `websocket` gem does
(confirmed by inspection, not yet spiked to failure) — so it's expected to
hit the first failure mode too, independent of masking.

**Consequence:** hand-rolling the RFC 6455 handshake and frame
parsing/generation in plain stdlib `Socket` code is no longer "the fallback
if the spike fails" — it's the only option among the two spiked so far.
Nothing rules out some other, unspiked gem, but the two most obvious
candidates both fail, for reasons specific enough (a metaprogramming idiom,
an unflagged C extension) that they don't generalize into "avoid gem X" —
they generalize into "any candidate gem needs this same live check before
being trusted," which is expensive per-gem. Hand-rolling a known, fixed
protocol (RFC 6455's handshake and frame format are short and stable) sidesteps
re-running this audit against a third gem.

## End-to-end spike: the hand-rolled path works (2026-09-01)

Ran the recommendation above: a throwaway stdlib-only server and client (not
committed), proving the whole shape this doc proposes, not just the codec in
isolation.

**Single connection, real client, real handshake.** A `TCPServer` accept
loop in the main Ractor; the accepted socket moved into a dedicated
`Ractor` via `Ractor#send(socket, move: true)` — confirming a real
`TCPSocket` supports Ractor's move protocol, the same way `pg`'s
`PG::Connection` does per the persistence doc, and unlike the plain
`Ractor.new(socket) { ... }` copy-by-argument path this doc hadn't checked
yet. Inside that Ractor: parse the raw HTTP `Upgrade` request, compute
`Sec-WebSocket-Accept` from `Digest::SHA1` + `Base64`, write the `101`
response, read one masked client frame (unmask it), write one unmasked
frame back. An independent client script (also stdlib-only) completed the
handshake, computed the expected `Sec-WebSocket-Accept` itself, and
confirmed a byte-for-byte match against what the server sent — then sent a
masked frame and read the echoed reply back correctly.

Caught and fixed the same bug this whole design exists to avoid repeating:
the first version defined `MAGIC = "258EAFA5-...".freeze` — sorry,
**forgot** the `.freeze` on the first pass, and got exactly
`Ractor::IsolationError: can not access non-shareable objects in constant
Object::MAGIC by non-main Ractor` from inside the connection Ractor. One
more live instance of the `Monk::VERSION` / `Model.table_name` bug class,
now personally reproduced rather than only read about.

**Three concurrent connections, proving isolation, not just correctness.**
Extended to a server accepting three real connections without waiting on
any of them, each in its own Ractor: one ordinary connection, one that
deliberately sleeps 1.5s inside its handler before replying, and one that
sends a payload engineered to raise inside the connection handler. Result:
the ordinary and the failing connection both completed in ~0.0s — neither
waited on the slow connection's Ractor — the slow one completed correctly
at ~1.5s, and the failing connection's exception was caught inside its own
Ractor and reported as `{error: "RuntimeError: simulated bad frame"}`
without touching the accept loop or either other connection. This is the
direct, empirical version of the "isolates failure the right way" claim
made earlier in this doc, not just an assertion.

**What this doesn't yet prove**, left for `PLAN-WEBSOCKET.md`: TLS
(`wss://`), fragmented frames (`FIN=0`, continuation opcode `0x0`),
close-handshake opcode `0x8` and ping/pong (`0x9`/`0xA`), payloads needing
the 64-bit length branch, and the registry/fan-out layer — this spike only
exercised one frame each direction per connection, not a long-lived
multi-message session.

## What Monk would own vs. what's a plain dependency

| Piece | Shape |
|---|---|
| HTTP `Upgrade` handshake + frame parsing | Own code — both spiked off-the-shelf gems fail under a real Ractor (see "Phase 0 result"); a third candidate would need the same live audit before being trusted |
| Connection-per-Ractor lifecycle | Monk owns this — mirrors `StateRactor` |
| In-process registry / broadcast | Monk owns this |
| Cross-process fan-out transport | Monk owns the API surface; Postgres or Redis does the transport work underneath |
| Reverse-proxy / deploy wiring | Documented, not generated — same posture as `docs/deploying.md` today |

## Open questions

1. ~~Hand-roll the handshake/framing in stdlib `Socket`, or take a
   dependency on a pure-Ruby WebSocket gem?~~ **Resolved by the Phase 0
   spike above: hand-roll it.** Both `websocket` and `websocket-driver` fail
   under a real Ractor. RFC 6455's handshake (compute
   `Sec-WebSocket-Accept` as `Base64(SHA1(Sec-WebSocket-Key +
   "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))`, both of which are stdlib —
   `Digest::SHA1`, `Base64`) and frame format (a short, fixed binary layout)
   are small and stable enough that owning them outright is less total risk
   than re-auditing a third gem against the same failure modes, and it
   avoids taking a dependency Monk would have to keep re-verifying across
   Ruby/gem version bumps the way the persistence doc had to for `pg`.
2. **One WebSocket process, or one co-located with each Kino worker?** A
   single process is simpler to reason about — same-process connections
   need no cross-process fan-out at all — but can't scale its connection
   count independently of anything; N co-located processes need
   cross-process fan-out (the Postgres/Redis question below) even for two
   connections on the same machine. Recommendation: start with one
   process; it's the simpler design and the one that defers the
   cross-process fan-out question the longest.
3. **`LISTEN`/`NOTIFY` or Redis for cross-process fan-out?** Postgres avoids
   new infrastructure, since persistence already lands `pg`. But
   `NOTIFY` payloads cap at 8000 bytes and delivery isn't guaranteed —
   a notification fires only for currently-listening connections, with no
   queue or replay. Redis pub/sub has the same "no durability" property but
   higher throughput and no payload cap. Not decided; there's no concrete
   fan-out requirement yet to decide it against.
4. **Does Monk generate reverse-proxy config** (an `nginx.conf` /
   `Caddyfile` snippet from `monk new`), or only document it by hand the
   way `docs/deploying.md` does for Render/Fly today? Leaning: document,
   not generate — consistent with the existing posture, and proxy config
   varies more by host than the Ruby side of this feature does.

## Explicitly out of scope (for this doc)

- Lobbying for or patching Kino to add hijack — the empirical finding above
  is that it's a deliberate exclusion in Kino's own design, not a gap to
  route around inside Kino.
- Socket.IO-style protocol/transport fallback (long-polling, etc.) — raw
  WebSocket (RFC 6455) only.
- Any client-side/JS helper library.
- A resolved horizontal-scaling design for the WebSocket process itself —
  flagged in open question 2, not answered here.

## Recommendation

Open question 1 is resolved and the core architecture is now verified
end-to-end, not just argued for: a real `TCPServer` accept loop, sockets
moved into dedicated per-connection Ractors, a hand-rolled RFC 6455
handshake and frame codec, true non-blocking concurrency across
connections, and isolated per-connection failure all work exactly as this
doc proposed (see "End-to-end spike," above). What's left is scope, not
uncertainty: TLS, fragmentation, close/ping-pong opcodes, and the
registry/fan-out layer are unexercised, and questions 2–4 (process
topology, fan-out transport, proxy config generation) are ordinary design
choices rather than empirical unknowns. That's enough to move this from
exploration to an implementation plan — see `PLAN-WEBSOCKET.md`, the same
transition `docs/persistence-ractor-connections.md` made once its own
Phase 0 held up.
