# Plan: 0.29, Live's first-connect resync and a baseline for offline

Status: planned 2026-11-27. Both parts directly on the release branch
`main_dev/v_0_29`, no feature branches. Two parts, independent, in this
order:

1. **Live resyncs after its first subscribe too**: a correctness fix for
   every Live app. Detailed in
   [`plan-live-first-connect-resync.md`](plan-live-first-connect-resync.md).
2. **Offline, level 0**: the page freezes, a banner says it's offline, and
   an installed app opened offline shows the app's offline page. From
   [`proposal-offline.md`](proposal-offline.md), settled.

Not in 0.29: anything of offline beyond level 0 (the app's); the
proposal's two helpers (storing one page safely in the worker, clearing
caches on sign-out), which wait until an app building level 1 shows what
they need to be, the guide covering both meanwhile; navigation without a
reload (not pursued,
[`history/proposal-navigate.md`](history/proposal-navigate.md)).

## Part 1: Live's first-connect resync

Built (2026-11-27): the change, the race test, the existing tests adjusted, ADR 0021, the docs. Found while doing it: every resync reconciles topics, so a topic the server denied was asked for again after the load's resync; the client now remembers denied topics until its next connection. Left: the checks on staging (below).

In short (the plan linked above has the problem, the options and the
tests):

- `monk_live.js`'s `connect()`: `needsResync = true` on every open, not
  only after the first; the resync runs after the server acknowledges the
  subscriptions, as on a reconnect.
- `monk-live:resynced` gets `{ reason: "first" | "reconnect" | "gap" }`.
- Cost accepted: one more page fetch per Live page load.
- ADR 0021 (amends 0011).

## Part 2: offline, level 0

Built (2026-11-27): `/_monk/up` with the deploy templates' health checks
(compose's in Ruby, since the slim image has no `curl`), `offline_state.js`
and `offline.js`, `monk_offline`, the boot check, the `sw.js` handler (with
navigation preload) and `offline.html`, Node and browser tests, the docs
and ADR 0022. Differences from below: a hidden page doesn't check (iOS
drops a hidden page's socket within seconds), and `offline.html` opened
at its own address goes to `/` once back. Left: the open checks.

### Decisions (the proposal's open details, settled here)

- **Where it lives:** `Monk::Pwa`, so on with `monk add pwa`, nothing to
  turn on. `/_monk/up` is in core: every app gets the health check, with
  or without Pwa.
- **The client:** its own file, `lib/monk/pwa/client/offline.js`, served
  at `/_monk/pwa/offline.js` and loaded by `monk_head` next to
  `register.js` (which stays about registration and install). Its
  decisions in a pure module, `offline_state.js`, tested under Node like
  Live's `protocol.js`.
- **The delay:** 2 s, fixed. A setting only if an app asks.
- **The events:** `monk-offline:offline` with `{ reason }`, and
  `monk-offline:online`, on `document`.
- **`offline.html`:** scaffolded into `public/` by `monk add pwa`, the
  app's file from then on; `Monk::Pwa.configure` fails the boot if it's
  missing, as for `sw.js`.
- **`[data-monk-online-only]`:** a documented CSS pattern, no Monk code.
- **The app's own failed fetches:** the client doesn't wrap `fetch`. An
  app that sees one dispatches `monk-offline:check` on `document`, and the
  client probes.

### `GET /_monk/up`

- In `Base#call`, before `dispatch` and `log_request`: `204`, empty body,
  `Cache-Control: no-store`, the security headers. No session, no
  database, not logged. Any other method: 405.
- Means "the process answers requests". A deeper check (database, Redis)
  is not this route.
- The deploy template uses it: Caddy's `health_uri /_monk/up` in the
  `reverse_proxy` block, and a compose `healthcheck` on the app service if
  the image has a tool to call it (to check: `curl`/`wget` in the image,
  else Caddy's check alone).

### The client: `offline.js`

State: online, or offline with a reason (`network`, `server`,
`unreachable`).

- **Signals:**
  - `navigator.onLine` and the `online`/`offline` events: `offline` means
    `network`, for sure;
  - `monk-live:disconnected` / `monk-live:connected`, when Live is on
    the page;
  - `monk-offline:check`, from the app.
- **Going offline:** a signal starts a 2 s timer. When it fires and the
  condition still holds, the client probes `/_monk/up` (`cache:
  "no-store"`), unless `navigator.onLine` is false (then `network`
  without a probe):
  - a network error: `unreachable` (`network` if `navigator.onLine` turned
    false);
  - 502, 503, 504: `server`;
  - 204: not offline (Live is still reconnecting, or the app's fetch
    failed for another reason); nothing shown.
- **While offline:** `<html data-monk-offline="<reason>">`, the banner
  shown, `monk-offline:offline` dispatched. The probe repeats with backoff
  (1 s doubling to 30 s) and jitter; `online`, `monk-live:connected` or a
  page shown again probe at once.
- **Back online** (a probe answers 204, or Live connects): the attribute
  and the banner go, `monk-offline:online`. Live's own resync updates the
  page; nothing else.
- **Link clicks while offline:** a capturing click listener on
  `document`: a left click with no modifier on a same-origin `<a href>`,
  no `target`, no `download`, not a `#hash` on the same page, is
  cancelled, and `<html>` gets `data-monk-offline-nudge` until
  `animationend` (or 1 s), for the app's CSS. Back can't be cancelled:
  the worker's fallback covers it.

`offline_state.js` holds: which reason a probe answer means, the backoff,
whether a click is one to block. The rest is wiring.

### `<%= monk_offline %>`

In `Pwa::Helpers`, next to `monk_install`:

```erb
<%= monk_offline %>
<%= monk_offline network: "Sei offline", server: "Server non raggiungibile, riprovo…",
                 unreachable: "Impossibile connettersi" %>
```

renders, hidden until the client shows it:

```html
<div class="monk-offline" data-monk-offline-banner role="status" hidden>
  <p class="monk-offline__text" data-monk-offline-reason="network">You're offline.</p>
  <p class="monk-offline__text" data-monk-offline-reason="server">Can't reach the server, retrying…</p>
  <p class="monk-offline__text" data-monk-offline-reason="unreachable">Can't connect.</p>
</div>
```

The client shows the banner and the text for the reason (the others
`hidden`). BEM classes, no styles. Nothing when Pwa isn't configured.

### The service worker: a fallback for page loads

In the scaffolded `public/sw.js`, replacing the "no fetch handler" note:

- `install`: put `/offline.html` (fetched with `cache: "reload"`) in a
  cache `monk-offline`, before `skipWaiting`.
- `fetch`: only `request.mode === "navigate"` and `GET`. `fetch(request)`
  as is; a network error, or a 502/503/504, answers with the cached
  `/offline.html` (status 503, `no-store`). Any other answer, redirects
  included, passes through untouched and is never stored. Every other
  request has no `respondWith`: the network, as today.
- **Keeping `offline.html` current:** once per worker start, after a page
  load that succeeded, refetch it in the background into the cache. An
  edited `offline.html` shows from the next start of the worker.
- Caches the app's code might clear must keep `monk-offline` (as
  `monk-pwa-app-windows` today): said in the file and the guide.

### `public/offline.html` (scaffolded)

Static, no user data: the app's name (filled by the generator, like the
manifest), "You're offline", a "Try again" button, and a short inline
script: on `online`, on the button, and on a backoff, probe `/_monk/up`
and `location.reload()` when it answers 204. The reload retries the URL
the person was opening (the worker answered that URL with this page).
Styles inline, so it needs nothing else cached. The app may grow it into a
cached personalized page (the guide's level 1).

### Tests

- **`/_monk/up`:** 204 with no body and `no-store`; not logged; no session
  cookie set; 405 for POST; answers with a database that's down (the test
  stops it or points at a wrong one).
- **`monk_offline`:** markup, overridden texts, escaping; empty without
  Pwa.
- **`Monk::Pwa.configure`:** fails without `public/offline.html`.
- **Generator:** `monk add pwa` writes `offline.html` with the app's name;
  the scaffolded `sw.js` has the handler.
- **`offline_state.js` under Node:** probe answers to reasons, backoff,
  click filtering.
- **Browser (headless Chrome, like Live's):**
  - offline with a page open (DevTools network emulation): banner after
    the delay with `network`, link clicks blocked with the nudge, back
    online clears it;
  - a short drop (under 2 s): no banner;
  - `/_monk/up` answering 503 (a test server): `server`;
  - a reload while offline: `offline.html`; online again: the page;
  - with Live: disconnected then reconnected, the banner follows.
- The full suite with 0 skips.

### Docs

- **`docs/guides/offline.md`** (linked from `pwa.md`): level 0 (what Monk
  does, the banner, styling `data-monk-offline` and the nudge, the
  events, `monk-offline:check`, `data-monk-online-only`); growing the
  offline page (level 1, the app's: rules for caching a personalized
  page, private data and sign-out, deploys, bounds, Safari's eviction);
  send later (level 2, the app's: the outbox and idempotency keys);
  level 3 out of scope.
- `pwa.md`: "The service worker" section rewritten (the fallback, the
  `monk-offline` cache).
- `deploying.md`: `/_monk/up` as the health check; the deploy templates.
- **ADR 0022:** "the service worker answers page loads only when the
  network or the server failed, with the app's offline page; nothing
  else goes through it".
- `upgrading.md`: for an app with Pwa, copy the new `sw.js` handler, add
  `public/offline.html`, `<%= monk_offline %>` in the layout, the
  Caddyfile's health check.
- The scaffold's `agents.md` (pwa, deploy): the pitfalls (never cache in
  the fallback, keep `monk-offline`, `monk-offline:check` after a failed
  fetch).
- `docs/roadmap.md`: 0.29's entry.

## Steps

Part 1 first (small, a bug), then part 2.

1. Part 1, as in its plan: the failing race test, the change, the existing
   tests adjusted, ADR 0021, the Live docs.
2. `/_monk/up` with its tests; the deploy templates.
3. `offline_state.js` and its Node tests.
4. `offline.js`, `monk_offline`, the `monk_head` tag, the configure check.
5. The `sw.js` handler and `offline.html` in the generator, their tests.
6. The browser tests for part 2.
7. Docs for part 2, ADR 0022, upgrading, roadmap.
8. The version bump and release notes.

## Open checks (on devices, with the chat app on staging)

- Installed iPhone app: swipe-close, airplane mode, open: `offline.html`;
  network back, "Try again" or wait: the app.
- A page open, airplane mode: the banner, links blocked; back: gone, the
  page updated by Live.
- A deploy with pages open: no banner (under 2 s), or `server` briefly
  if it takes longer.
- Part 1: a message sent while the other person opens the chat shows
  without a reload; no flicker at load; the extra fetch's cost on the
  chat list.

## Done when

- Both parts in, the suite green with 0 skips, the docs written.
- The open checks done on staging and noted here.
