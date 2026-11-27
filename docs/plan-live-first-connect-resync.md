# Plan: Live resyncs after its first subscribe too (0.29)

Status: planned 2026-11-27, from the navigation discussion
([`history/proposal-navigate.md`](history/proposal-navigate.md), Decision):
Monk fixes this race and leaves the navigation model to the app. In 0.29
(`plan-0-29.md`, part 1). Built 2026-11-27 on `main_dev/v_0_29`; left: the
staging checks in "Done when".

## The problem

A patch published between a page's render and its socket's first
subscribe is lost, silently, on every page load.

- The server renders the page at T0. The browser parses it, loads
  `monk_live.js`, opens the socket and subscribes at T1: hundreds of ms on
  a phone, more on a slow network or a cold start.
- A publish in between goes to nobody: the topic isn't registered for this
  page yet.
- Nothing notices. Live resyncs only after a *re*connect
  (`needsResync = everConnected`, `lib/monk/live/client/monk_live.js:209`,
  false on the first connect), and `seq` is per connection
  (`lib/monk/live/session.rb:159`), starting at 1 with the first envelope
  after the subscribe, so no gap shows.
- The page stays wrong until the next patch to that region or a reload. In
  a chat: a message sent while the other person opens the chat is missing
  from it.

ADR 0011's rule already says it: patches are only an optimization over
"the page can always be refetched", and a client that may have missed
some must refetch. The first connect is such a moment, and was left out.

## The change

**On the first connect too, resync once the server has acknowledged the
subscriptions.** In `connect()`'s `onopen`: `needsResync = true`, not
`everConnected`. The `subscribed` handler already resyncs when
`needsResync` is set, after the ack, so a publish after the ack arrives as
a patch and one before it is in the refetched page. No window left.

The ack is a sound point in every fanout: `Session#subscribe` replies only
after `register_many` returns, and the registry is a local Ractor `ask`
(the Postgres and Redis fanouts listen on one fixed channel/pattern for
the whole process, so a registered topic receives from then on).

**`resynced` gets a reason:** `{ reason: "first" | "reconnect" | "gap" }`
(`resync()` takes it and passes it on; coalesced triggers report the
last). An app that does something on `resynced` (scroll to the newest
message, local times) can tell the first one apart, or not care.

`everConnected` is no longer needed for this; kept only if something else
reads it.

### Cost, accepted

- **One more page fetch per Live page load** (pages with no
  `data-live-topic` open no socket and don't change). The server renders
  every Live page twice. Phoenix LiveView does the same by design (the
  HTTP render, then the socket's mount): it's the price of a correct page
  without per-topic state on the server.
- **A morph right after load.** Usually a no-op (the page didn't change);
  focus, typed text, `data-live-ignore` and `<details open>` are kept as in
  any resync. What app JS changed in the DOM at load is morphed back to
  the server's markup, as after any resync today; apps already handle that
  on `resynced`, now on every load. To check in the chat app: no visible
  flicker (local times, avatars).

### Considered, not chosen

- **The page carries its render time; at subscribe the server says whether
  a topic was published to since** (resync only then). Saves the second
  fetch on most loads, but needs a last-published time per topic shared by
  every process (the fanout keeps none), plus clock rules. Recorded as the
  optimization to make **only if the second fetch is measured to matter**.
- **Subscribe at render time** (the server registers a pending
  subscription with a token, buffers its patches, and the socket claims it).
  Buffers per page view, a TTL, cross-process claiming: far heavier.
- **Resync only if the first ack comes "late".** Any delay can hide a
  publish; a threshold is a guess, not a fix.

## Tests

- **The race, in a browser** (`test/live_client_browser_test.rb`): a page
  whose route publishes to its own topic right after rendering (before
  the client can subscribe), changing a region; the browser ends up
  showing the published state. Fails before the change.
- First connect: one `resynced` with `reason: "first"`, after `subscribed`.
  Reconnect and gap: `reason` `"reconnect"` and `"gap"`.
- Existing tests that count `resynced` (reconnect, coalescing, large page,
  retry with backoff) now see one more at load: wait for the first one
  before acting, and count from there.
- A page with no topics: no socket, one request.
- `test/js/protocol.test.js`: only if the decision moves into
  `protocol.js` (it's one assignment; probably not).
- The full suite with 0 skips (Postgres, Redis, floci running).

## Docs

- **ADR 0021** (amends 0011): a page resyncs once after its first
  subscribe is acknowledged, as after a reconnect; the accepted cost, the
  considered options above.
- `docs/guides/live.md`: the lifecycle (render, connect, subscribe,
  resync), `resynced` on every load and its `reason`; why code run at load
  that changes the DOM also belongs on `resynced`.
- `docs/guides/upgrading.md`: `resynced` now fires on every page load,
  with `reason`; one more request per Live page load.
- The scaffold's `agents.md` Live pitfalls, if it lists `resynced`.
- `docs/roadmap.md`: the entry.

## Steps

1. Browser test for the race, failing.
2. The change in `monk_live.js` and the `reason` detail; the race test
   passes.
3. Existing Live browser tests adjusted to the first resync; full suite.
4. ADR 0021, guides, upgrading, roadmap, `agents.md`.
5. In the chat app: no flicker at load, and the second fetch's cost on the
   heaviest Live page (the chat list with its presence topics): server
   time and bytes per load, before and after.

## Done when

- The race test passes and the suite is green with 0 skips.
- The docs above are written.
- On the chat app's staging: a message sent while the other person opens
  the chat shows without a reload; no flicker at load; the extra fetch's
  cost noted in this plan, and if it's too high, the "published since"
  rule above becomes its own plan.
