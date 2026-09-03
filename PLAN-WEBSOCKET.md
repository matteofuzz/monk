# Monk WebSocket — implementation plan

Branch: not yet created — nothing in this plan is implemented. Companion
doc: `docs/websocket.md` (why Kino can't carry this in-process, the Phase 0
gem spike, the end-to-end hand-rolled spike this plan builds out for real).

Like `PLAN.md`, this develops in small, gradual, red → green cycles. Each
numbered step is one vertical slice: one failing test against its seam,
then the minimum code to pass it. Phase 0 is the exception, per
`PLAN-PERSISTENCE.md`'s precedent — it's a spike, not TDD, and it already
ran and gated everything below.

Every phase runs on Monk's target Ruby, 4.0.6 (`.ruby-version`). Ractor
behavior is measured on 4.x directly, never inferred from a 3.x result or
from a library's own claims about itself — Phase 0 below is the reason that
rule exists in the first place.

## Phase 0 — Spikes: does anything off-the-shelf survive a real Ractor, and does hand-rolling it actually work? (already run, gated everything below)

Not TDD — two throwaway spikes, already run 2026-09-01, full detail in
`docs/websocket.md`.

**Gem spike, failed for both candidates tried.** `websocket` (1.2.11, pure
Ruby) fails unconditionally: every core method is built with
`define_method` + a block, and such a method is only callable from the
Ractor that defined it, permanently, regardless of load order —
`RuntimeError: defined with an un-shareable Proc in a different Ractor`.
`websocket-driver` (0.7.7) fails separately: its native masking extension
was never flagged Ractor-safe (`Ractor::UnsafeError`), and its own
delegator methods use the same `define_method` pattern, so it is expected
to fail twice over. Neither is usable. New general finding recorded in
`docs/ractor.md`: `define_method` with an unfrozen block is unusable across
Ractors at all — the fix (`Ractor.make_shareable` the block first) requires
patching the gem's own internals, not something callers can do from
outside.

**Hand-rolled spike, succeeded.** A real `TCPServer` accept loop in the
main Ractor, each accepted socket moved into a dedicated Ractor via
`Ractor#send(socket, move: true)`, a from-scratch RFC 6455 handshake
(`Digest::SHA1` + `Base64`, both stdlib) and frame codec. Verified against a
real, independent client script: correct handshake, correct masked/
unmasked frame round-trip, three concurrent real connections with no
head-of-line blocking (a deliberately slow connection didn't delay the
other two), and one connection's simulated internal error caught and
reported without affecting the accept loop or any other connection. Full
detail: `docs/websocket.md` → "End-to-end spike."

**Consequence for every phase below**: no gem dependency. Everything is
hand-rolled on stdlib `Socket`/`Digest::SHA1`/`Base64`, and the phases below
turn the spike's ad hoc scripts into a tested `Monk::WebSocket` primitive.

## Decisions locked in before Phase 1

Each of these is a recommendation from `docs/websocket.md` promoted to a
plan assumption. Reversing one invalidates the phases that rest on it.

1. **A separate process, not a Kino feature.** Confirmed architecturally
   impossible in-process (`docs/websocket.md` — Kino never exposes a raw
   socket to Ruby, hijack included). `Monk::WebSocket::Server` is a
   standalone process an app boots on its own port; a reverse proxy in
   front routes to it and to Kino separately. No change to `lib/monk/base.rb`
   or anything Kino-facing.
2. **No gem dependency — hand-rolled RFC 6455**, per Phase 0. `Monk::WebSocket`
   owns the handshake and frame codec outright.
3. **One dedicated Ractor per connection**, the socket moved in via
   `Ractor#send(socket, move: true)`, mirroring `StateRactor`'s
   mutable-thing-stays-hidden trick applied to a socket instead of a value.
4. **One `Monk::WebSocket::Server` process to start, not one co-located per
   Kino worker.** Simpler to reason about; defers the cross-process
   fan-out question (Phase 6) as long as possible. Revisit only if a real
   scaling need shows up.
5. **Identity reuses `Monk::Auth` unmodified, and the token-carrying
   question is resolved, not deferred.** The WS process registers its own
   `Monk::Persistence` connection and calls `Monk::Auth.configure` against
   the same database `docs/auth-sessions.md` already designs — no new auth
   mechanism, no new token format. Per that doc's "The WebSocket case"
   (2026-09-01): browser-originated connections authenticate via the
   session cookie, carried automatically because cookies aren't
   port-scoped (requires the reverse proxy to route `/ws` on the same host
   as the HTTP process, not a separate subdomain, unless the cookie sets
   `Domain=` explicitly); non-browser connections authenticate via
   `Authorization: Bearer`, set directly on the handshake request, since
   only the browser's `WebSocket` JS API is header-restricted. No
   `?token=` query parameter and no first-message auth handshake — both
   considered and superseded by this resolution.
6. **Cross-process fan-out (Postgres `LISTEN`/`NOTIFY`) is deferred**,
   Phase 6, built only once a real fan-out requirement exists — mirrors
   how `PLAN-AUTH.md` deferred cookies to its own Phase 9. Phases 1–5 ship
   a fully working single-process WebSocket server with in-process
   broadcast.
7. **`Monk::WebSocket` is opt-in**, like persistence backends and
   `Monk::Auth`: `require "monk/websocket"` explicitly. `require "monk"`
   alone must not load it.
8. **Reverse-proxy config is documented, not generated.** No `monk new`
   output for nginx/Caddy — consistent with `docs/deploying.md`'s existing
   posture for Render/Fly, and proxy config varies more by host than the
   Ruby side of this feature does.

## Seams

- **Seam R — the RFC 6455 codec's own public API**: handshake
  request-parsing/response-building and frame encode/decode, tested
  directly against Hashes/Strings with no socket involved (mirrors how
  `PLAN.md` Seam C tested `StateRactor` against its own interface).
- **Seam S — connection lifecycle**: the accept loop, the socket-move into
  a dedicated Ractor, and the `Monk::WebSocket::Connection` object handed
  to app code — tested against a real `TCPServer`/`TCPSocket` pair, since
  there's no meaningful fake for "accepted a real socket."
- **Seam T — the in-process registry/broadcast**: tested directly against
  its own interface first (fake connection handles, no real sockets
  needed), then with real connections.
- **Seam U — real concurrent Ractor integration**: multiple real,
  concurrently-accepted connections — including a slow one and a failing
  one — the automated version of Phase 0's manual spike, and the only
  place non-blocking accept and failure isolation are actually proven
  (mirrors `PLAN.md` Seam D and `PLAN-PERSISTENCE.md` Seam G).
- **Seam V — `monk-consumer-test` end-to-end**: the gem consumed from
  outside the repo, a real `Monk::WebSocket::Server` process serving real
  client connections.

## Phase 1 — RFC 6455 codec (Seam R)

1. `Monk::WebSocket::Handshake.accept_key(client_key)` — pure function,
   `Base64.strict_encode64(Digest::SHA1.digest(client_key + MAGIC))`. The
   `MAGIC` constant is declared `.freeze`d from the start — Phase 0's
   spike hit exactly this bug once already (`Ractor::IsolationError` on an
   unfrozen constant); this step exists partly so the test suite proves it
   can't recur silently.
2. `Monk::WebSocket::Handshake.parse_request(raw_headers)` extracts
   `Sec-WebSocket-Key` and validates `Upgrade: websocket` /
   `Connection: Upgrade` are present; raises
   `Monk::WebSocket::HandshakeError` (naming what's missing/invalid) for a
   non-WebSocket or malformed request, rather than an unhandled `NoMethodError`
   the way the spiked-away gems' internals would have on garbage input.
3. `Monk::WebSocket::Handshake.response_for(raw_headers)` returns the full
   `101 Switching Protocols` response string.
4. `Monk::WebSocket::Frame.decode(bytes)` parses a complete frame's header
   (opcode, `FIN`, masked flag, length) and unmasks the payload if masked.
   Covers all three length encodings (7-bit, 16-bit extended, 64-bit
   extended) — the spike only exercised short payloads.
5. `Monk::WebSocket::Frame.encode(payload, opcode:)` produces wire bytes
   for the same three length ranges, unmasked (server frames are never
   masked, per RFC 6455).
6. Decoding a truncated/malformed byte sequence raises
   `Monk::WebSocket::ProtocolError` (naming what's wrong), not a raw
   `NoMethodError`/`ArgumentError` — this is the specific category of
   failure Phase 0's gem audit surfaced (an unhandled internal error where
   a graceful protocol error was intended), so the fix is asserted
   directly, by name, here.
7. Close (`0x8`), ping (`0x9`), and pong (`0xA`) opcodes decode correctly.
   Acting on them is Phase 3 (close) and Phase 5 (ping/pong) — this step
   only proves the codec recognizes them.

## Phase 2 — Connection-per-Ractor lifecycle (Seam S)

8. `Monk::WebSocket::Server.new(port:, bind: "0.0.0.0")` opens a
   `TCPServer` and exposes `#run { |connection| ... }` — the accept loop,
   intended to be the entire body of a small standalone script (e.g.
   `bin/websocket_server`), never embedded in the same process as Kino
   (Decision 1).
9. Each accepted socket is moved into a dedicated Ractor via
   `Ractor#send(socket, move: true)` (proven in Phase 0's spike). Assert
   directly that the accept loop returns to `TCPServer#accept` without
   waiting for that Ractor to finish — the non-blocking property the spike
   demonstrated manually, now a committed test.
10. The connection's Ractor performs the handshake (Seam R), then yields a
    `Monk::WebSocket::Connection` to the caller-supplied block — `#read`
    (blocks for one decoded message) and `#write(payload)` (encodes and
    sends one frame). This is Monk's `Context`-equivalent for a WS
    connection: the socket and frame machinery are never exposed directly
    to app code.
11. A malformed/incomplete handshake (garbage bytes, missing
    `Sec-WebSocket-Key`) writes a `400 Bad Request` and closes the socket,
    rather than raising unhandled inside the connection Ractor.
12. An exception raised inside the caller-supplied block is caught inside
    that connection's own Ractor, the socket is closed, and neither the
    accept loop nor any other connection is affected — asserted here as a
    single-connection unit test; Seam U (Phase 7) proves it under real
    concurrency.

## Phase 3 — Close handshake & disconnects (Seam S extended)

13. Receiving a close frame (`0x8`) triggers a close frame back and closes
    the socket — the RFC 6455 closing handshake, not a bare TCP close.
14. `Connection#close(code:, reason:)` sends a close frame and closes the
    socket — the server-initiated path.
15. An abrupt client disconnect (TCP EOF, no close frame) is observed as
    `#read` returning `nil`; the connection's Ractor exits cleanly either
    way.

## Phase 4 — In-process registry & broadcast (Seam T)

16. `Monk::WebSocket::Registry` — a dedicated Ractor (mirrors
    `StateRactor`'s shape) holding the live set of connection handles keyed
    by an app-assigned channel/subject. `register(key, port)`,
    `broadcast(key, payload)`, `unregister(key, port)`. Tested first
    against its own interface with fake connection ports — no real sockets
    needed to prove the registry's own bookkeeping.
17. A connection registers itself after a successful handshake and
    unregisters on close or disconnect (Phase 3) — including the error
    path from Phase 2 step 12, so a crashed handler never leaks a stale
    registry entry.
18. Real integration: two real connections register under the same key;
    broadcasting to that key delivers the message to both, and to neither
    of a third connection registered under a different key.

## Phase 5 — Identity: `Monk::Auth` from a second process (Seam S extended)

19. The WS process's own boot script `require`s `monk/persistence/pg` and
    `monk/auth` and calls the same `Monk::Persistence.register` /
    `Monk::Auth.configure` the HTTP process uses, against the same
    database — no new auth mechanism.
20. **How the token reaches the handshake — resolved, per Decision 5.**
    During handshake parsing (Seam R, `Handshake.parse_request`), extract
    identity in this order: (a) an `Authorization: Bearer` header if
    present — the non-browser/S2S path; (b) otherwise the session cookie
    from the `Cookie` header — the browser path, arriving automatically
    because cookies aren't port-scoped. No `?token=` query parameter and
    no first-message auth: both were considered in the prior pass and are
    superseded now that the cookie carries automatically for the case that
    actually needs it (a browser can't set the `Authorization` header
    either way, so there's no case left for a query-param fallback to
    solve).
21. **`Origin` allowlist validation, on every handshake, checked before
    step 22's `verify` call.** A cookie-authenticated handshake is
    forgeable cross-origin the same way a CSRF'd form post is (Cross-Site
    WebSocket Hijacking) — neither `SameSite` nor `PLAN-AUTH.md`'s CSRF
    double-submit header reaches a WS handshake, so this is the
    WS-specific mitigation, not optional hardening. `Monk::WebSocket::
    Server.new` takes an `allowed_origins:` list; a handshake whose
    `Origin` header isn't on it is rejected with `403` before
    `Monk::Auth.verify` ever runs, regardless of whether the credential
    was a valid cookie. Bearer-authenticated (non-browser) connections
    have no `Origin` header to check by construction — this step applies
    to the cookie path only, mirroring `require_csrf!`'s own Bearer
    exemption in `PLAN-AUTH.md`.
22. `Monk::Auth.verify` runs against whichever of step 20's (a)/(b) was
    found, *after* step 21's `Origin` check passes and *before* the
    handshake's `101` response is sent. An invalid or missing token on
    both channels closes the connection with a `401`-equivalent (a plain
    HTTP `401` response instead of `101`, since the connection hasn't
    upgraded yet) rather than registering an anonymous connection.
23. Ping/pong (`0x9`/`0xA`, decoded since Phase 1) are answered
    automatically by the connection's Ractor — a `ping` gets an immediate
    `pong` without reaching the caller-supplied block, keeping a long-lived
    authenticated connection alive through idle reverse-proxy timeouts.

## Phase 6 — Cross-process fan-out (Seam T extended) — deferred, build only when a real requirement exists

Not built until Decision 4 is revisited (a second `Monk::WebSocket::Server`
process, or an HTTP-triggered WS push, actually shows up as a requirement).
Sketched here so Phase 4's registry API doesn't have to change shape later.

24. A dedicated "listener" Ractor per WS process holds one `PG::Connection`
    in `LISTEN` mode; a `NOTIFY` payload is translated into a local
    `Registry.broadcast` call — the registry's public API (step 16) is
    unchanged, this just feeds it from a second source.
25. `Monk::Persistence::Pg`'s existing per-Ractor connection lifecycle
    (`PLAN-PERSISTENCE.md` Phase 1) is reused for the listener connection —
    no new connection-management code.
26. `NOTIFY` payload size (8000 bytes) and delivery guarantees (dropped if
    nothing is listening, no queue/replay) are documented as constraints
    on what `broadcast` payloads may safely carry — not silently assumed.

## Phase 7 — Real Ractor/concurrency integration (Seam U)

27. Automate Phase 0's manual spike: N real, concurrently-accepted
    connections against a real `Monk::WebSocket::Server` — one ordinary,
    one that deliberately blocks inside its handler, one that sends a
    malformed frame. Assert (not just observe) that the ordinary and
    failing connections both complete without waiting on the slow one, and
    that the failing connection's error is caught and reported without
    affecting the other two or the accept loop — the committed version of
    `docs/websocket.md`'s "End-to-end spike," in the same spirit as
    `test/ractor_integration_test.rb`'s hammer test for `StateRactor`.
28. N real connections registered under the same channel (Phase 4),
    broadcasting from a real Ractor other than any connection's own, all
    receive the message correctly.

## Phase 8 — `monk-consumer-test` end-to-end proof (Seam V)

29. The consumer app gains `require "monk/websocket"`, a `bin/websocket_server`
    script, one channel/handler, and (if Phase 5 landed) the same
    `Monk::Auth`/`Monk::Persistence` config its HTTP side already uses.
30. Verified manually: run the WS process locally, connect with a real
    client (a small script, or a generic tool) once with a valid
    `Authorization: Bearer` header and once with a real cookie jar shared
    from the HTTP process's login flow, send/receive a message, broadcast
    across two connections, and confirm a handshake from a disallowed
    `Origin` is rejected. Documented as a verification step, not an
    automated cycle — mirrors `PLAN.md` step 21 and `PLAN-AUTH.md`
    step 38.
31. `docs/deploying.md` gains a worked reverse-proxy example (nginx or
    Caddy, whichever the existing Render/Fly cases make cheaper to show)
    routing `/ws` to the WebSocket process's port and everything else to
    Kino, on the **same host** as the HTTP process (per Decision 5) —
    documentation only, per Decision 8.

## Explicitly out of scope for this plan

TLS/`wss://` termination (left entirely to the reverse proxy — standard
practice, and consistent with Monk's own socket code never touching
certificates); permessage-deflate or any other WebSocket extension;
Socket.IO-style fallback transports (long-polling, etc.); `monk new`
generating reverse-proxy config (Decision 8); any client-side/JS helper
library; per-connection rate limiting beyond what the OS/host provides;
horizontal scaling of the WebSocket process itself beyond the `LISTEN`/
`NOTIFY` fan-out sketched in Phase 6; a resolved answer to Phase 6's own
Postgres-vs-Redis question, since there's no concrete fan-out requirement
yet to decide it against.
