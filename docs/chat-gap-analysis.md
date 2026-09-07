# Building a 1:1 chat app on Monk — gap analysis

Status: analysis, 2026-09-07. No code written. Scope of the exercise: a
chat product with **1:1 text messages only**, served to two kinds of
client — a browser and a CLI. The question this doc answers is not "how
would the app be structured" alone, but "what does Monk already cover,
and where does it come up short" — the same posture `docs/websocket.md`
took before that feature was built.

## 1. What Monk already covers

| Need | Covered by | State |
| --- | --- | --- |
| HTTP app, routing, params, JSON | `Monk::Base` | solid |
| HTML UI | `Monk::Views` (ERB compiled at boot) + `Monk::Assets` | solid |
| Identity, login, sessions | `Monk::Auth` (passwordless, `Bearer` **and** cookie+CSRF) | solid |
| DB + migrations | `Monk::Persistence::Pg`, `Pg::Migrator` | minimal, usable |
| Live delivery | `Monk::WebSocket` (own process, one Ractor per connection, `Registry` fan-out) | works, single process |
| Project skeleton | `monk new chat --auth` | ready |

`docs/auth-sessions.md` already resolved the part that usually costs the
most: a browser-originated WS connection carries the `session_token`
cookie automatically (cookies aren't port-scoped, so this holds in
development with no proxy at all), and a non-browser client sets
`Authorization: Bearer` directly on the handshake.
`Server.new(authenticate: true)` verifies either one before the `101`.

## 2. Architecture

Three moving parts, no infrastructure Monk doesn't already assume:

- **HTTP process (Kino)** — login, conversation list, message history,
  serves the browser client.
- **WebSocket process** (`bin/chat_server`) — one
  `Monk::WebSocket::Server`, `authenticate: true`, `allowed_origins:` set.
- **Postgres** — `login_tokens`/`sessions` plus the chat tables; the
  source of truth and the offline/backfill path.

In production a reverse proxy routes `/ws` to the WS process and
everything else to Kino, **on the same host** (`docs/deploying.md` §3).

The decision that keeps the MVP small: **messages are written over the
WebSocket only, never over HTTP.** The HTTP process cannot push into the
WS process — `Registry` is an in-memory, per-process structure, and
cross-process fan-out via `LISTEN`/`NOTIFY` is deliberately deferred
(`PLAN-WEBSOCKET.md` decision 6). Writing over WS sidesteps that
entirely, and HTTP keeps only read endpoints.

## 3. Data model

`Monk::Auth` gives identity as a bare email string (`sessions.subject`).
For 1:1 that is nearly enough on its own:

```
users     (id, email UNIQUE, handle, created_at)   -- optional for the MVP
messages  (id BIGSERIAL, sender, recipient, body, created_at)
          index on (sender, recipient, id) and (recipient, id)
```

No `conversations` table: a 1:1 conversation *is* the unordered pair
`(sender, recipient)`. `users` earns its place only if addresses should
be handles/display names rather than raw emails.

## 4. Wire protocol

JSON envelopes, one per frame:

- client → server: `{"type":"send","to":"b@x.com","body":"hi","client_id":"<uuid>"}`
- server → client: `{"type":"message","id":42,"from":…,"to":…,"body":…,"at":…,"client_id":…}`
- server → client: `{"type":"error","reason":"…"}`

Per inbound message the handler validates, `INSERT`s, then broadcasts
twice: to the recipient, and back to the sender (so the sender's other
tabs/devices stay in sync). The echoed `client_id` lets a client
reconcile its optimistic bubble against the persisted row.

**Registry keying.** Each connection subscribes to *itself*:
`connection.subscribe(REGISTRY, connection.subject)`. Note that
`Connection#subscribe` supports exactly one key per connection (a single
`@port`/`@key` — `lib/monk/websocket/connection.rb`), which fits this
shape exactly but rules out per-room subscriptions later without a
framework change.

**Offline and reconnect, in one mechanism.** A message to an offline
recipient is simply a row in the DB. On connect a client calls
`GET /conversations/:peer/messages?since_id=N`. That single endpoint
covers offline delivery *and* gaps from a dropped connection, so the MVP
needs no ack protocol.

## 5. Clients

**Browser** — ERB views plus one ES module (`public/js/chat.js`) using
the stock `WebSocket` API; the session cookie rides along by itself. No
build step, consistent with this repo's import-map convention
(`docs/views.md`).

**CLI** — login is `POST /auth/request`, then the token (printed or
emailed) is redeemed at `GET /auth/callback/:token`, and the resulting
session token is stored in e.g. `~/.config/monk-chat`. Then a WS
connection with `Authorization: Bearer`.

> **The CLI needs a WebSocket *client*, and Monk has none.**
> `Monk::WebSocket::Frame.encode` never masks — correct, since RFC 6455
> forbids servers from masking — but the same RFC *requires* masking on
> every client→server frame. So the CLI either takes a gem
> (`websocket-client-simple`, `faye-websocket`) or hand-rolls roughly
> fifty lines of masking client. This is the one place where "just use
> Monk" does not hold, and it is worth deciding before Phase 5.

## 6. Gaps

Concrete, ordered by how likely a chat workload is to hit them.

1. ~~**`Pg::Model` cannot express message history.**~~ **Fixed
   2026-09-07.** `where` now supports comparison operators (`gt`/`gte`/
   `lt`/`lte`/`ne`), `IN`, `ORDER BY`, and `LIMIT` — see
   `docs/persistence-ractor-connections.md` decision 4's update. `OR` is
   still out of scope: a sender/recipient-pair query still needs a raw
   `Pg.checkout` block in an app-level repository object.
2. ~~**`Registry` fan-out is fragile under a race.**~~ **Fixed
   2026-09-07.** `broadcast` now rescues `Ractor::ClosedError` per port
   (`lib/monk/websocket/registry.rb`) instead of letting it propagate out
   of the registry Ractor's own loop — a closed port used to kill that
   Ractor outright, taking down delivery for every key in the whole
   process, not just the dead connection's. A send to a closed port is now
   skipped, the rest of the broadcast still goes out, and the dead port is
   dropped from that key so it isn't retried on the next broadcast.
3. ~~**No server-initiated ping.**~~ **Fixed 2026-09-07,** as the ping
   thread option rather than an app-level heartbeat: `Server.new(...,
   ping_interval: 30)` spawns a thread per connection
   (`Connection#start_heartbeat`) that sends an unsolicited ping on that
   cadence. A spec-compliant client — every browser's own WebSocket
   implementation included, no app JS involved — answers it with a pong
   automatically, which is what actually resets a reverse proxy's idle
   timer. Off by default (`ping_interval: nil`), so an existing server
   behaves exactly as before until it opts in.
4. **Auth is verified once, at the handshake.** A revoked or expired
   session keeps a live socket indefinitely. Needs periodic re-verify in
   the read loop, or a maximum connection lifetime.
5. **No fragmentation reassembly, no payload cap.** `fin` is decoded but
   ignored, so a continuation frame (opcode `0x0`) falls through and
   reaches app code as if it were a message; and a claimed 64-bit length
   is read with no ceiling (`lib/monk/websocket/frame.rb`,
   `Connection#read_frame`). Fine for well-behaved browsers sending short
   text; a cap is cheap insurance on a public endpoint.
6. **One WebSocket process, structurally.** Horizontal scaling, or any
   HTTP→WS push, needs the deferred `LISTEN`/`NOTIFY` layer
   (`PLAN-WEBSOCKET.md` Phase 6). Acceptable for a long time — but the
   ceiling is one process, and §2 is shaped around that.
7. **Spam and abuse.** `Monk::Auth::RateLimiter` (per-process,
   `StateRactor`-backed) is reusable as-is for a per-subject message
   rate limit. Nothing else exists.
8. **Platform maturity.** Ractors, Ruby 4 and Kino are all experimental.
   For a dogfooding project that is the point, but it remains the
   largest non-technical risk.

Gaps 2–5 are each small, and arguably belong upstream in Monk rather than
worked around in the chat app.

## 7. Suggested phasing

0. `monk new chat --auth`
1. Migration plus a `Message` repository (raw SQL for history)
2. HTTP: login pages, conversation list, `GET /conversations/:peer/messages`
3. WS process: authenticate, subscribe to own subject, handle `send`,
   persist, dual broadcast
4. Browser client: views, `chat.js`, optimistic send, `since_id` catch-up
   on connect
5. CLI client: token store plus the WS-client decision from §5
6. Hardening: heartbeat, session re-verify, rate limit, payload cap,
   registry `rescue`

Phases 1–3 are the real work; 4 and 5 are roughly a day each; 6 is small
but should not be skipped.

## 8. Open questions

1. **Identity** — emails as addresses (nothing new to build), or a
   `users` table with handles?
2. **CLI WebSocket client** — a gem, or a hand-rolled masking client
   inside the chat app?
3. **Scope** — are read receipts, typing indicators and presence
   explicitly out, or a later phase? Presence is nearly free: the
   registry already knows who is connected.
4. **Framework or app** — fix gaps 2–5 in Monk itself (they are
   framework-level defects), or work around them in the chat app for now?
