# Reactive UI via server-pushed HTML partials over the WebSocket

Status: proposed, no code written, 2026-09-17. Grew out of a monk_talk
exploration session that started as "which vanilla-JS reactive library
fits a chat contact list" (Alpine, petite-vue, Lit, VanJS,
`@preact/signals-core`, Attractive.js all considered) and ended somewhere
else: the reactive layer doesn't belong in monk_talk's JS at all, it
belongs here, next to `Monk::WebSocket` and `Monk::Views`. This doc is
the first design pass at that, in the same "no code yet, write down the
shape first" posture `docs/websocket.md` and `docs/chat-gap-analysis.md`
took before those were built.

## The problem this is answering

monk_talk needs a contact list with live profiles/statuses in addition
to the 1:1 messages `docs/chat-gap-analysis.md` already covers. Both are
the same shape: **server-owned state that changes and needs to reach an
open browser tab without a page reload.** The chat MVP solved this once,
by hand, in `monk_talk/public/js/chat.js` — a hand-rolled `WebSocket`
with reconnect backoff (`reconnectDelay` doubling to a 30s cap) and a
`pendingByClientId` map so a client's own optimistically-rendered
message doesn't get duplicated when the server echoes it back.

Doing that again per feature (contacts, statuses, and whatever comes
after) means re-deriving the same reconnect/dedup/state-sync logic in
JS each time, and a real reactive UI framework (Alpine, Lit, etc.) only
replaces the *rendering* half of that problem — it still needs a data
layer to keep client state in sync with server state, which is exactly
the kind of two-source-of-truth bug class this framework should be
sparing app authors from.

## The proposed split

**Server-owned state → rendered HTML fragments, pushed over the socket,
patched into the DOM.** Client never holds a copy of contact/status/
message state to keep in sync — the server is the only source of truth
and the client just displays whatever HTML it's told to show.

**Client-local state → a very light declarative library, or nothing.**
Anything with no server truth to synchronize (collapse a panel, open a
profile modal, copy an email to clipboard, local form validation)
doesn't need a data layer at all. Attractive.js (declarative
`data-action`/`data-target` attributes, no JS written, no state) fits
this tier well *because* it has no data binding — that was a
disqualifier for rendering the contact list itself, but it's the right
shape once list rendering moves server-side. Plain vanilla JS modules
remain the fallback for anything client-local that's still genuinely
stateful (the reconnect backoff and optimistic-send tracking in
`chat.js` are exactly that — not declarative-attribute material either
way, regardless of which library owns the sprinkles).

This is the same shape as Rails' Hotwire (Turbo Streams + Stimulus) or
Phoenix LiveView, deliberately lighter and more limited: no virtual DOM,
no client-side data layer, no full-page diffing — just targeted fragment
replace/morph messages over the connection `Monk::WebSocket` already
owns.

## Prior art considered (and why this is a distinct, narrower thing)

| Project | What it is | Why not just use it |
| --- | --- | --- |
| Phoenix LiveView | Full server-rendered reactivity, stateful diffing, form/event binding built into a client runtime | Elixir/Phoenix-specific runtime and protocol; the reference point for "how far this pattern can go," not something to port |
| Hotwire (Turbo Streams + Stimulus) | `<turbo-stream>` elements over WS/SSE with `action="replace/append/remove"`, small controllers for local JS | Closest existing match to this proposal's shape. `turbo.js` is ~40KB and brings its own conventions (Stimulus controllers, its own connection management) that would need to coexist with `Monk::WebSocket`'s own connection lifecycle rather than replacing it |
| htmx + `ws` extension | Hypermedia swaps over a WS connection, `hx-swap-oob` for updating the same element wherever it appears on the page | Mature and small (~14KB + extension), but still an external client dependency with its own connection-ownership model to reconcile with Monk's |
| Datastar | SSE/WS-driven fragment patching + small reactive signals, ~15KB single file | Newer (2024/2025), smaller ecosystem, less battle-tested; same "external protocol to adopt" issue as htmx |
| idiomorph / morphdom | Just the DOM-morphing primitive (~3KB), no protocol | The most likely actual building block — pairs with a Monk-defined message envelope instead of adopting someone else's swap conventions |

None of these are Monk-shaped: they either bring their own connection
management (competing with `Monk::WebSocket`'s per-connection Ractor
model) or their own view-rendering conventions (competing with
`Monk::Views`' boot-time-compiled ERB, `docs/views.md`). The proposal
below is to take the *narrowest* useful idea from this table — a
morph-target primitive, à la idiomorph, driven by a Monk-defined message
shape — rather than adopting a full library.

## Shape of the primitive (sketch, not a spec)

- Server side: a way to render an existing `Monk::Views` template to a
  string (not a full HTTP response) and push it down an open
  `Monk::WebSocket::Server` connection, addressed to a DOM target:
  `{ type: "patch", target: "#contact-42", html: "<li>...</li>" }`.
- Fan-out: reuses whatever `Monk::WebSocket::Registry` already does for
  chat message delivery (`docs/chat-gap-analysis.md` §2) — a status
  change is just another event broadcast to the connections that should
  see it.
- Out-of-band-style updates: the same entity (a contact's status dot)
  may need to update in more than one place on the page at once
  (sidebar row, open DM header). Rather than adopting htmx's
  `hx-swap-oob` convention wholesale, this likely wants its own simple
  rule — e.g. `target` accepts a CSS selector matched with
  `querySelectorAll`, not just `getElementById`, so one push can patch
  every matching node.
- Client side: a small (~3KB-class) morph library, not a framework —
  swap `innerHTML` replace for a proper morph so focus/scroll state in
  unaffected siblings survives a patch.

## Open questions / risks

- **Render cost on broadcast.** A status change potentially re-renders
  and re-sends a fragment per affected connection (every contact who
  has this user's status visible), not just per state change. Needs a
  cost model before this is load-bearing for anything high-frequency
  (typing indicators are the extreme case — likely still fine if
  throttled, matching how `docs/chat-gap-analysis.md` already treats
  ephemeral vs. persisted messages differently).
- **Ordering vs. optimistic client state.** `chat.js`'s
  `pendingByClientId` pattern exists because the client renders
  optimistically before the server confirms. Any patch protocol needs
  the same kind of "don't double-render what I already showed myself"
  rule, or optimistic UI has to be dropped in favor of always waiting
  for the server round-trip.
- **Where this lives relative to `Monk::WebSocket`.** Whether this is a
  new `Monk::WebSocket` feature (message type) or a separate layer on
  top is undecided — needs its own design pass once `docs/websocket.md`'s
  multi-process fan-out questions (RedisFanout, gap 6 in
  `docs/chat-gap-analysis.md`) are settled, since a patch broadcast has
  the same cross-process delivery problem a chat message does.
- **No ADR yet.** Like `docs/websocket.md` before it, the "own
  primitive vs. adopt htmx/Datastar" call is exactly the kind of
  decision `docs/adr/` exists for, once this moves from proposal to
  build.

## Relation to other docs

- `docs/chat-gap-analysis.md` — the 1:1 chat MVP this pattern would
  extend to cover contacts/statuses.
- `docs/websocket.md` — the connection/process model this would build
  on top of.
- `docs/views.md` — the ERB compilation this would need to reuse for
  fragment rendering, not just full-page rendering.
- `docs/auth-sessions.md` — identity-on-the-socket, unchanged by this
  proposal.
