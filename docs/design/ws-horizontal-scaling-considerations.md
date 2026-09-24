# WS horizontal scaling: what it means and what's actually unbuilt

Status: notes, 2026-09-24. Written while scoping
`../history/plan-live-pg-fanout.md`, to pin down exactly what "WS
horizontal scaling" excludes from that plan, rather than leaving it as a
vague out-of-scope bullet.

## What it means

Running **more than one `bin/websocket_server` process at the same time**,
each holding a portion of the total open WebSocket connections — instead
of today's setup, where exactly one WS process holds every connection.

## Why it's a separate concern from cross-process fanout

Both `Monk::WebSocket::RedisFanout` and the proposed `PgFanout`
(`../design/live-pg-fanout.md`) exist to bridge the Kino ↔ WS-process split.
That split is mandatory at **N=1 WS process already** — Kino can never
hold a raw socket (`../design/websocket.md`), so `config.ru` and
`bin/websocket_server` are always at least two processes, regardless of
scaling. Fanout answers "how does a publish from an HTTP route reach the
one WS process," not "how many WS processes exist." These are orthogonal:

- **Fixed, unavoidable, solved by fanout:** Kino process ↔ WS process(es),
  always ≥2 processes.
- **Optional, unbuilt, not touched by the fanout work:** WS process
  count > 1.

`../history/plan-websocket.md` Decision 4 explicitly deferred the second
one: "One `Monk::WebSocket::Server` process to start... revisit only if a
real scaling need shows up." Nothing in this repo builds it today, and
neither the Redis nor the Postgres fanout changes that.

## What would/wouldn't actually work if you tried N>1 today

Worth being precise rather than hand-wavy about this, since it's easy to
either overclaim ("fanout already solves scaling") or underclaim ("nothing
would work"):

- **The broadcast mechanism itself would probably already work.** Both
  fanout implementations use pub/sub — a publish from Kino reaches *every*
  subscriber, not just one. If two `bin/websocket_server` processes both
  pointed at the same Redis/Postgres, each would independently receive
  every broadcast and relay it to its own locally-connected clients. This
  was never designed as "point to exactly one WS process" — the one-WS-
  process assumption comes from `plan-websocket.md` Decision 4, not from
  anything in the fanout code itself.
- **But it's never been tested that way.** Every test that exercises a
  real second process (`plan-live.md` Phase 7, `plan-live-pg-fanout.md`
  Phase 4) runs exactly one WS process. N>1 is an untested assumption, not
  a verified fact.
- **`Registry#count(key)` would silently undercount.** Each WS process
  only knows about connections registered in *its own* process. An app
  feature like "3 people are viewing this page" would only ever see its
  own process's local slice with N>1 WS processes splitting connections,
  not the true total. No cross-process count exists.
- **Reverse-proxy load balancing across WS processes is undocumented and
  unbuilt.** New WS connections would need to be distributed across the N
  processes. `plan-websocket.md` Decision 8 documents proxy config rather
  than generating it, and that documentation has only ever covered the
  single-process case.

## Consequence for fanout-transport work

Any plan that swaps or adds a fanout transport (Redis, Postgres, or
anything else) should treat "WS horizontal scaling" as explicitly out of
scope: it doesn't need to test, fix `#count`, or document deployment for
N>1 WS processes. That remains a distinct, still-open feature — tracked by
`plan-websocket.md` Decision 4 — regardless of which transport ends up
carrying the Kino↔WS bridge.
