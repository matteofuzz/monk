# Monk::Live — implementation plan (first draft)

Branch: not yet created — nothing in this plan is implemented. Companion
doc: `docs/reactive-partials.md` (the why, prior art, and the sketch this
plan turns into steps).

Same posture as `PLAN-WEBSOCKET.md`: small red → green slices, one failing
test per seam, minimum code to pass. Every phase runs on Ruby 4.0.6 and
Ractor behavior is measured, not assumed. This is a *tentative* plan: the
decisions below are recommendations to be confirmed (or ADR'd) before the
phase that depends on them.

## Naming and packaging

`Monk::Live`, in `lib/monk/live.rb` + `lib/monk/live/` like every other Monk
module. Opt-in like `Monk::WebSocket` and `Monk::Auth`: `require "monk/live"`
explicitly, `require "monk"` alone never loads it (mirrors
PLAN-WEBSOCKET.md Decision 7). It depends on `Monk::WebSocket` and
`Monk::Views`; neither depends on it. Starts in this gem; the one-way
dependency keeps extraction into a separate gem cheap. (An earlier draft
had a top-level `MonkLive`; dropped, see ADR 0008.) JS-side names stay
`monk-live` (`public/monk_live.js`, `monk-live:*` DOM events).

## Decisions to make up front

Written up front as ADRs (2026-09-19), after the Phase 0 spikes, in `docs/adr/`:
0007 (own envelope + client, vendored idiomorph), 0008 (layer above
`Monk::WebSocket`), 0009 (topics are opaque names, deny-by-default
authorization), 0010 (render once in the publisher's Ractor, frozen
payload; covers decisions 4 and 5), 0011 (resync by page refetch). The
list below is the working summary; the ADRs are the record.

1. **Own envelope + own tiny client vs. adopt htmx-ws / Datastar / Turbo.**
   Recommendation: own envelope, own ~100-line client JS, vendored morph
   library (idiomorph). Reason from the doc: everything else brings its
   own connection ownership that competes with `Monk::WebSocket`.
2. **Layer, not a WebSocket feature.** Monk::Live sits on top of
   `Monk::WebSocket` (uses `Server`, `Connection`, `Registry`) and adds
   nothing to its wire code. The WS layer already carries opaque text
   frames; Monk::Live defines what's *in* them. Resolves the doc's "where
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
  `Monk::Live.patch "contacts:7", to: "#contact-42", partial: "contacts/row", contact: c`.
  Same for `append`, `prepend`, `remove` (no partial), and
  `Monk::Live.batch topic do |b| ... end` for several ops in one frame.
  `topic` is the only positional argument; `to:`, `partial:` and `mode:`
  are reserved keyword names, everything else is passed to the partial as
  locals. Reserved names must be documented (a local called `to` is the
  price of this syntax) and rejected loudly, not shadowed silently.
- Authorization at boot, deny by default:
  `Monk::Live.authorize("contacts:*") { |subject, topic| ... }`.

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
- Client-local state (panels, modals) stays out of Monk::Live entirely
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

- **Ractor spike — DONE 2026-09-19 (Ruby 4.0.6), decision 5 confirmed.**
  Throwaway script (not committed) rendering a partial with a nested
  partial, escaping and `asset_path` from non-main Ractors.
  - **Works with no changes to `Monk::Views`:** a plain
    `Monk::Context.new({})` (or even `new(nil, nil)`) in a non-main
    Ractor renders correctly: HTML-escaping intact, nested `render`,
    `asset_path`, both a one-shot Ractor and a long-lived renderer
    Ractor answering over a `Ractor::Port`. ~3µs per render (10k renders
    in ~30ms), so render cost is not the bottleneck; fan-out is.
  - **Requires `Monk.freeze!` in the rendering process.** Without it:
    `Ractor::IsolationError ... @registry from Monk::Views`.
    `Monk::WebSocket::Server` only calls it when `authenticate: true`, so
    Monk::Live must call it itself at boot and fail fast with a clear error
    (ADR 0003 posture), not leave it to the app.
  - **The default layout wraps a fragment** (`render` without
    `layout: false` returned `<html><body>…`). Monk::Live's renderer must
    force `layout: false`; never trust the caller to remember.
  - **Locals are read as `locals[:contact]` in templates, not bare
    `contact`.** This is existing Monk behavior (README/`docs/views.md`),
    and the "keyword locals" publish syntax maps onto it directly. Live
    partials must document it.
  - **Locals crossing into another Ractor** work either as a shareable
    value (`Ractor.make_shareable`) or copied (a mutable Struct sent
    via `send` rendered fine). The result is a `Monk::Views::Raw`
    String that is *not* shareable; it gets copied on send/broadcast,
    which is cheap at fragment sizes but means "render once, send many"
    copies the string per port unless we freeze it first
    (`String#freeze` / `make_shareable`, to be measured).
  - **New rule for live partials: request-independent.** A detached
    Context has no `params`/`env`/session, so a partial that calls
    `params` or a per-request helper (e.g. a `current_user` helper) would
    render wrong or raise. Everything a fragment needs must come in as
    locals. Worth a lint/doc callout; per-viewer fragments pass the
    viewer as a local.
  - **Not yet tested:** a real `Monk::Persistence::Model` instance as a
    local (shareability/copy behavior across the boundary). Test in
    Phase 1 against the real persistence layer, not a stand-in Struct.
  - **Consequence for the design:** publishing can render in the
    publisher's own Ractor (a request worker) with no extra Ractor and
    no new machinery; a dedicated renderer Ractor is an option, not a
    need. Phase 1 shrinks to "a `Monk::Live` renderer that builds a
    detached Context, forces `layout: false`, and ensures freeze".
- **Client spike — DONE 2026-09-19, morph approach confirmed with one
  gap.** ~60-line client + idiomorph 0.7.3 (9KB minified) against a real
  `Monk::WebSocket::Server` pushing hard-coded envelopes, driven in real
  Chrome. Throwaway, not committed.
  - **Holds:** patching a sibling row kept focus, typed value, selection,
    an open `<details>` and the scroll position of the pane. Patching the
    node that *contains* the focused input kept the same DOM node, focus,
    value and selection (idiomorph's `ignoreActiveValue: true`), so
    "focus is protected automatically" costs one option, not custom code.
  - **`data-live-ignore` works** via `beforeNodeMorphed` returning false:
    a widget with local text state survived a patch of its parent.
  - **Multi-match selector works:** one envelope with `.status-dot`
    patched 4 nodes (`querySelectorAll`), as the doc's OOB idea needs.
  - **Control confirms the need:** a naive `outerHTML` replace replaced
    the node, dropped focus and cleared the typed value.
  - **append/remove and `seq` gap detection** behave (gap event fired
    with `expected: 9, got: 20`).
  - **The gap: client-only state inside a patched region is reset.** A
    `<details>` the user opened *inside* the patched node closed after the
    morph, because the server HTML has no `open` attribute (idiomorph
    syncs attributes to the server's). Focus/value are special-cased by
    idiomorph; `open`, checked-ness of non-focused controls, scroll of
    inner containers and similar are not. Design consequences: (a) v0 rule,
    documented: state the user can change locally must live *outside*
    patched regions, be re-rendered by the server, or be marked
    `data-live-ignore`; (b) consider a `beforeAttributeUpdated` callback
    that preserves `open` on `<details>` by default. Decide in Phase 4.
  - **Not covered by the spike:** reconnect/resubscribe behavior, the
    page-refetch resync morph (a much bigger morph than a fragment),
    interplay with Attractive.js state, IME composition and text
    selection outside the focused input, and behavior on Safari/Firefox
    (only Chrome tested). Carry into Phase 4/5 tests.
- **Fan-out measurement — DONE 2026-09-19.** Real `Monk::WebSocket::Registry`,
  N consumer Ractors each holding a registered `Ractor::Port`, 20 rounds,
  median. Measures Ractor-to-Ractor delivery only (no socket writes, no
  Redis), on an 8-core Mac; treat as order-of-magnitude, noise is
  visible. `broadcast_call` = how long `Registry#broadcast` blocks;
  `last_receive` = until the last consumer has the payload.

  | N conns | payload | unfrozen: call / last | frozen: call / last |
  | --- | --- | --- | --- |
  | 100 | 0.5 KB | 2.4 / 2.7 ms | 2.0 / 3.0 ms |
  | 100 | 50 KB | 3.5 / 3.5 ms | 2.2 / 3.2 ms |
  | 500 | 0.5 KB | 28 / 28 ms | 18 / 29 ms |
  | 500 | 50 KB | 36 / 37 ms | 19 / 39 ms |
  | 1000 | 0.5 KB | 120 / 128 ms | 58 / 113 ms |
  | 1000 | 5 KB | 130 / 135 ms | 71 / 136 ms |
  | 1000 | 50 KB | 177 / 177 ms | 34 / 92 ms |

  - **Render cost is irrelevant; delivery cost is per-subscriber.**
    Fragment size barely moves the numbers (0.5 KB to 50 KB is within
    noise for unfrozen up to 500 conns). Rendering is ~3µs; fan-out to
    1k is ~100ms. "Render once, send many" is right, but the thing to
    budget is subscriber count, not template cost.
  - **Freezing the payload helps the publisher side** (call time roughly
    halves at 500-1000 conns; 5x at 1k x 50 KB) because a shareable
    String is passed by reference instead of copied per port. It does
    not shorten time-to-last-receive much at small sizes. Decision:
    Publisher freezes/`make_shareable`s the envelope string before
    broadcast (one line, no downside).
  - **Scaling is worse than linear:** 100 → 500 → 1000 conns took ~2.5 →
    28 → 120 ms. Some of that is consumer Ractors all waking and
    contending for cores at once, not registry work, so this overstates
    the registry's own cost; but it means "1k subscribers on one topic"
    is a ~100ms event, and 5-10k would be seconds. Not a problem for the
    monk_talk contact-list scale (recipient topics fan out to a handful
    of connections per user), a real limit for one hot topic.
  - **Broadcast blocks the whole Registry.** It is one single-threaded
    Ractor, so during a 1k-subscriber broadcast (~60-120ms) every
    `register`/`unregister`/`count`, on *any* topic, waits. Connections
    opening or closing stall behind a big fan-out. Acceptable for v0;
    if it bites, shard the Registry by topic hash (N registry Ractors)
    or move fan-out off the register/unregister path. Recipient topics
    (default) keep per-topic subscriber counts small, which is another
    point in their favor.
  - **Not measured:** socket write cost per connection (likely the real
    dominant cost with slow clients: `Connection#write` is blocking, so
    one slow client's full send buffer stalls only its own relay thread,
    but that should be verified), the Redis hop, memory per connection
    Ractor at 1k+, and batching many small patches (the `batch` op) vs
    many broadcasts. Carry into Phase 2 and 7 tests.

### Phase 1 — Fragment rendering

`Monk::Views` gets a way to render a template *without a layout and
without an HTTP response*, from a context built for it. Tests: partial
renders to a String; HTML-escaping (ADR 0005) still applies; unknown
partial raises the same boot/render errors as pages; works from a
non-main Ractor. Partial naming convention: `views/_name.erb`, or reuse
existing views with `layout: nil` — decide from the spike.

### Phase 2 — Envelope + publisher

`Monk::Live::Envelope` (build/serialize, shareable, frozen) and
`Monk::Live::Publisher`, exposed as `Monk::Live.patch/append/prepend/remove/batch`
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
mobile links) or too coarse, add `Monk::Live.snapshot("contacts:*") { |subject, topic| ... }`
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
optimistic rendering in Monk::Live**; client-local sprinkles may show a
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
Monk::Live example; write `docs/live.md` and ADRs from decisions 1–5;
integrate in monk_talk for the contact list and statuses as the
acceptance test (the actual reason this exists). Rate-limiting and
throttling of high-frequency topics (typing indicators) stay app-level per
the existing chat scope decision.

## Explicitly out of scope for v0

Client → server event binding (`live-click`, forms over WS), per-viewer
diffing, server-held per-connection state à la LiveView, a virtual DOM,
presence tracking, history/replay beyond snapshot-on-subscribe.

## Risks worth watching

- ~~Phase 0's Ractor rendering result could force a redesign of Phase 1~~
  Resolved by the spike: rendering from a non-main Ractor works as-is.
  Remaining Phase 0 items (client morph, fan-out cost) are still open.
- Authorization (Phase 3) leaking patch content is the worst failure mode;
  fragments must never be rendered with data the subscriber can't see.
- Per-viewer fragments defeat render-once and re-create the cost problem;
  keep them a deliberate exception.
- `morph` + client-local library state (Attractive.js) interplay: morphing
  can wipe attribute-driven local state; test explicitly in Phase 4.
