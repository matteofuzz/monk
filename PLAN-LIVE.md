# MonkLive — implementation plan (first draft)

Branch: not yet created — nothing in this plan is implemented. Companion
doc: `docs/reactive-partials.md` (the why, prior art, and the sketch this
plan turns into steps).

Same posture as `PLAN-WEBSOCKET.md`: small red → green slices, one failing
test per seam, minimum code to pass. Every phase runs on Ruby 4.0.6 and
Ractor behavior is measured, not assumed. This is a *tentative* plan: the
decisions below are recommendations to be confirmed (or ADR'd) before the
phase that depends on them.

## Naming and packaging

`MonkLive` (top-level, not `Monk::Live`) — opt-in like `Monk::WebSocket`
and `Monk::Auth`: `require "monk_live"` explicitly, `require "monk"` alone
never loads it (mirrors PLAN-WEBSOCKET.md Decision 7). It depends on
`Monk::WebSocket` and `Monk::Views`; neither depends on it. Open: ship in
the same gem (`lib/monk_live.rb` + `lib/monk_live/`) or a separate gem
later. Start in-repo; the one-way dependency keeps extraction cheap.

## Decisions to make up front (each gets a short ADR before its phase)

1. **Own envelope + own tiny client vs. adopt htmx-ws / Datastar / Turbo.**
   Recommendation: own envelope, own ~100-line client JS, vendored morph
   library (idiomorph). Reason from the doc: everything else brings its
   own connection ownership that competes with `Monk::WebSocket`.
2. **Layer, not a WebSocket feature.** MonkLive sits on top of
   `Monk::WebSocket` (uses `Server`, `Connection`, `Registry`) and adds
   nothing to its wire code. The WS layer already carries opaque text
   frames; MonkLive defines what's *in* them. Resolves the doc's "where
   does this live" question without waiting on RedisFanout.
3. **Topic-addressed, not connection-addressed.** App code says
   "topic `contact:42` changed"; it never handles connection handles.
   Topics map onto `Registry` keys (Symbols, per RedisFanout's constraint).
   **Decided:** a topic is just a name, so both models work on the same
   primitive — recipient topics (`contacts:7`, each user subscribes to
   their own channel; publisher loops over recipients) and entity topics
   (`contact:42`, clients subscribe per watched entity; one publish per
   change). Recipient topics are the documented default because they fit
   deny-by-default authorization; entity topics get no special code and
   need only an app policy that can answer "may this subject watch this
   entity?". Per-viewer fragments (content differing per recipient) only
   fit recipient topics.
4. **Render once, send many.** A broadcast renders the fragment a single
   time and fans the string out, when the fragment is identical for all
   subscribers. Per-viewer fragments (different content per recipient)
   are an explicit, separate, slower path.
5. **Rendering happens where?** Views are compiled into a module Context
   includes and must be callable from a Ractor. Open: does the publishing
   Ractor (a request worker) render, or the connection Ractor? Recommend
   the publisher renders, so subscribers just forward bytes.

## Ergonomics (decided)

Illustrative syntax; the shape is fixed, exact names can still move.

Server:

- Partials are ordinary `Monk::Views` templates. Pages mark live regions
  with a helper: `<ul id="contacts" <%= live_topic "contacts:#{current_user.id}" %>>`
  (accepts several topics; expands to `data-live-topic`).
- Publishing uses **keywords**:
  `MonkLive.patch "contacts:7", to: "#contact-42", partial: "contacts/row", contact: c`.
  Same for `append`, `prepend`, `remove` (no partial), and
  `MonkLive.batch topic do |b| ... end` for several ops in one frame.
  `topic` is the only positional argument; `to:`, `partial:` and `mode:`
  are reserved keyword names, everything else is passed to the partial as
  locals. Reserved names must be documented (a local called `to` is the
  price of this syntax) and rejected loudly, not shadowed silently.
- Authorization at boot, deny by default:
  `MonkLive.authorize("contacts:*") { |subject, topic| ... }`.

Client:

- `<script src="/monk_live.js" defer></script>` and nothing else: the
  runtime finds `[data-live-topic]`, subscribes, morphs patches in,
  reconnects with backoff and re-subscribes.
- **DOM events only, no JS API:** `monk-live:patched`,
  `monk-live:connected`, `monk-live:disconnected`, `monk-live:resynced`,
  each carrying `detail` (`topic`, `target`, `op`).
- **Focus is protected automatically:** the morph step skips the focused
  input/textarea/contenteditable (and its value/selection). `data-live-ignore`
  is the manual override for anything else (an open widget, a
  third-party-managed node).
- Client-local state (panels, modals) stays out of MonkLive entirely
  (Attractive.js or plain attributes).

## Wire protocol (server → client), v0

JSON text frames, one envelope each. Small and closed set of ops:

- `patch` — `{op, target, html, mode}`; `mode` ∈ morph (default),
  replace, append, prepend, remove. `target` is a CSS selector applied
  with `querySelectorAll` (one push, every matching node — the doc's
  out-of-band answer).
- `batch` — several ops applied in one animation frame, in order.
- `ack`/`nack` for client-originated events (Phase 5 only).

Every envelope carries a monotonically increasing `seq` per connection so
the client can detect a gap after reconnect and ask for a resync rather
than silently rendering a stale page. Client → server in v0: `subscribe`
/ `unsubscribe` (topic) and `resync`. Nothing else.

## Phases

### Phase 0 — Spikes (throwaway, not TDD)

- **Ractor spike:** can a `Monk::Views` template be rendered to a String
  from a non-request Ractor with no `Context` from an HTTP request? What
  does a "detached context" need (helpers, `h`, no `rendering` state)?
  This gates Phase 1's whole design; do it first.
- **Client spike:** hand-write the ~100-line client against a static
  `Monk::WebSocket` server pushing hard-coded envelopes; confirm morph
  preserves focus, scroll, and an open `<details>` in untouched siblings.
- Measure: cost of render-once-send-many for N=1k connections on one
  Registry topic (feeds the doc's render-cost open question).

### Phase 1 — Fragment rendering

`Monk::Views` gets a way to render a template *without a layout and
without an HTTP response*, from a context built for it. Tests: partial
renders to a String; HTML-escaping (ADR 0005) still applies; unknown
partial raises the same boot/render errors as pages; works from a
non-main Ractor. Partial naming convention: `views/_name.erb`, or reuse
existing views with `layout: nil` — decide from the spike.

### Phase 2 — Envelope + publisher

`MonkLive::Envelope` (build/serialize, shareable, frozen) and
`MonkLive::Publisher`, exposed as `MonkLive.patch/append/prepend/remove/batch`
with the keyword syntax from "Ergonomics": render once →
`Registry#broadcast(topic, envelope_json)`. Tests include: reserved keyword
names rejected, remaining keywords reach the partial as locals. Tests against
a real `Registry` with fake ports; verifies one render regardless of
subscriber count; verifies dead ports are self-healed (already Registry
behavior — assert we don't regress it).

### Phase 3 — Subscription & authorization

A connection-side handler: on `subscribe`, check the connection's
`subject` (from `Monk::Auth`) is allowed the topic via an app-supplied
policy callable, then `Registry#register`. Default is deny. Without this,
any authenticated user could subscribe to any topic — this is the
security-critical slice. Tests: allowed, denied, unauth'd connection,
unsubscribe on disconnect (no leaked registrations).

### Phase 4 — Client runtime

`public/monk_live.js`, served via `Monk::Assets`, plus vendored morph
lib. Owns: applying envelopes, `seq` gap detection → resync (page
refetch, Phase 5), reconnect with backoff (absorbs the logic hand-written
in monk_talk's `chat.js`), re-subscribe of the topic set after reconnect,
automatic focus protection + `data-live-ignore`, and the `monk-live:*` DOM
events (no JS API). Tested with a headless
DOM (decide: jsdom via node, or browser-driven; check what the repo
already uses for JS, if anything).

### Phase 5 — Resync and initial state

The hard correctness slice. After (re)connect, or on a `seq` gap, the
client must converge to current server state without missed patches.
**Decided:** resync is a **full page refetch, morphed in** (Turbo's
approach): the client re-fetches the current page URL and morphs the
result over the DOM, then resumes patches. No snapshot API, no second
definition of what a topic renders, always correct because it reuses the
page's own view. Patches are therefore purely an optimization over "the
page can always be re-fetched". Tests: kill a connection mid-stream,
publish, reconnect, assert converged DOM; assert focus-protection and
`data-live-ignore` also hold during the refetch morph; assert a page that
now returns 401/redirect stops the runtime rather than morphing a login
page over the app.

**Possible future evolution (not v0): explicit snapshots.** If a full
refetch proves too heavy (large pages, frequent reconnects on flaky
mobile links) or too coarse, add `MonkLive.snapshot("contacts:*") { |subject, topic| ... }`
returning per-target partials, so a reconnect re-renders only the regions
subscribed to instead of the whole page. Costs to weigh then: a second
definition of the region's markup that can drift from the page's initial
render (mitigate by having the page view render the same partial), and a
naming convention tying topics to regions. Trigger to revisit: measured
refetch cost/latency in monk_talk, not speculation. Nothing in the v0
protocol should preclude it (`resync` stays a client → server message the
server may answer either way).

### Phase 6 — Optimistic UI rule

Resolve the `pendingByClientId` question. Recommendation for v0: **no
optimistic rendering in MonkLive**; client-local sprinkles may show a
pending state, and the server round-trip is the only thing that writes
server-owned DOM. Revisit only if latency demands it; if so, patches carry
an optional `client_id` so the client can replace, not duplicate.

### Phase 7 — Multi-process

Nothing new should be needed if the Publisher only goes through the
`Registry`-shaped interface: `RedisFanout` wraps it transparently. This
phase is a verification slice — run the Phase 2/5 tests through
`RedisFanout`, confirm the render-once fragment (a plain String) survives
the Redis hop, and confirm `seq` is assigned per-connection at the edge
(not by the publisher, or it breaks across processes).

### Phase 8 — Scaffold, docs, first consumer

Extend the `websocket_server` scaffold (`lib/monk/templates`) with a
MonkLive example; write `docs/live.md` and ADRs from decisions 1–5;
integrate in monk_talk for the contact list and statuses as the
acceptance test (the actual reason this exists). Rate-limiting and
throttling of high-frequency topics (typing indicators) stay app-level per
the existing chat scope decision.

## Explicitly out of scope for v0

Client → server event binding (`live-click`, forms over WS), per-viewer
diffing, server-held per-connection state à la LiveView, a virtual DOM,
presence tracking, history/replay beyond snapshot-on-subscribe.

## Risks worth watching

- Phase 0's Ractor rendering result could force a redesign of Phase 1
  (and of decision 5); everything downstream is provisional until it runs.
- Authorization (Phase 3) leaking patch content is the worst failure mode;
  fragments must never be rendered with data the subscriber can't see.
- Per-viewer fragments defeat render-once and re-create the cost problem;
  keep them a deliberate exception.
- `morph` + client-local library state (Attractive.js) interplay: morphing
  can wipe attribute-driven local state; test explicitly in Phase 4.
