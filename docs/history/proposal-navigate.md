# Proposal: page navigation without a reload (Monk Navigate)

Status: **not pursued**, decided 2026-11-27. Kept as history of the
discussion; the proposal below is as it was drafted on 2026-11-26.

## Decision

**Monk fixes the race in Live, and leaves the navigation model to the
app.** No `navigate.js`, no visit API, no setting.

- **The race (a bug today, for every Live app):** the server renders a page
  at T0 and its socket subscribes at T1 (hundreds of ms to over a second
  later on a phone). A patch published in between is lost: Live resyncs
  only on a reconnect (`needsResync = everConnected`, false on the first
  connect), and `seq` is per connection (`lib/monk/live/session.rb`), so no
  gap shows. Fixing it is generic and small: resync on the first connect
  too (one more fetch per page load), or the page carries its render time
  and the server says at subscribe whether a topic was published since
  (cheaper, more code). To choose in its plan.
- **Navigation is the app's choice:** a multi-page app reconnecting its
  socket on each page (correct once the race is fixed), or, when scale or
  feel asks for it, one page with panels and a single socket. Monk takes
  on neither model.

Why not Navigate: most of its "Why" is already covered (avatars: the
cacheable photo route, 0.28.x; presence: `Monk::Presence`'s grace; the
blank flash: cross-document view transitions, a line of CSS), and what's
left (reconnect churn, scroll kept across pages) only matters to some
apps, at some scale, at the price of a client whose long tail is Turbo
Drive's and a rule on every app's JS (run again after each swap). See also
[`proposal-offline.md`](../proposal-offline.md), level 0, which doesn't
depend on it.

Possible later, only if an app proves the need: a small public hook for
Live to reconcile topics after the app inserts a `data-live-topic` region
itself (e.g. a `monk-live:reconcile` event), for apps that load panels in
place.

## Why

A Monk app is a set of server-rendered pages. Each click on a link loads a
new document, which:

- shows images the page had a moment ago from scratch (an app's avatars
  flash on every switch between its main tabs);
- closes the Live WebSocket and opens a new one: subscribe again, and a
  disconnect and reconnect for presence;
- parses the app's JS and CSS and Monk's clients again;
- blanks the screen between pages in an installed iPhone app, and loses the
  scroll position of whatever stays the same (a list next to a detail
  pane).

Live already does the hard part on every reconnect (ADR 0011): it refetches
the page's URL, morphs `<body>` with idiomorph, keeps focus, and reconciles
the topics. Navigation is the same operation for another URL, plus history.

## What it could be

An opt-in client, `navigate.js`, served from the gem like Live's. When an app
turns it on, a click on one of its own links fetches the next page's HTML,
morphs it into `<body>`, and `pushState`s the URL. The server renders exactly
what it renders today: every page stays a complete page, reachable by URL.

**Both ways, always.** Off by default: an app that doesn't turn it on works
as today, document per page. On, every link can opt out, and anything the
client isn't sure of becomes an ordinary full load of the same URL. Without
JS, or if `navigate.js` fails to load, the app is the plain multi-page app it
is today.

## Behaviour (first sketch)

1. **Turning it on:** one setting, read by `<%= monk_head %>`, which then adds
   the client (e.g. `Monk::Settings` `navigate: true`, or an option in
   `config/live.rb`; see open questions). It works without Live too: an app
   with no topics still gets navigation.
2. **Which clicks it takes:** a left click with no modifier key on an
   `<a href>` to the same origin, no `target`, no `download`, not marked
   `data-monk-navigate="off"` (on the link or an ancestor), not a link to a
   different part of the same page (`#hash` only). Everything else is the
   browser's. Forms are not taken in this version (a Monk app posts with
   `fetch` anyway).
3. **The fetch:** `GET` the URL with `Accept: text/html` and
   `cache: "no-store"`, aborted if another click comes first. Only a 200
   HTML answer is swapped in. Anything else (an error, a 401, a redirect to
   another origin, a non-HTML answer) becomes a full load of that URL, so
   the browser shows what it would have shown. A same-origin redirect that
   ends on 200 HTML is swapped in with the final URL.
4. **The swap:**
   - `<title>` from the new page;
   - `<body>`'s attributes copied (Live's `data-live-topic` is often there);
   - `<body>`'s content morphed with idiomorph, keeping matching elements
     (and so their loaded images and scroll positions);
   - `<head>`: if the new page's scripts or stylesheets differ from the
     current ones (a deploy changed an `asset_path` fingerprint), a full
     load instead of a swap;
   - inline `<script>`s in the new body are not run: page code belongs in
     the app's scripts, with delegated handlers (already Monk's guidance for
     Live).
5. **A new page is new state.** A navigation's morph does not apply Live's
   rules for a patch: `data-live-ignore` subtrees and the focused field's
   value are replaced like the rest (otherwise a draft would follow you from
   one chat to the next when the composer has the same id). Only an element
   marked `data-monk-permanent`, with an `id`, stays as the client has it
   when the next page has the same id (a connection banner, an audio
   player).
6. **History:** before leaving, the current entry's state records the
   window's scroll position. Back and forward (`popstate`) fetch that URL
   and swap it in (no cache in this version), then restore the scroll. A
   new page scrolls to the top, or to its `#hash`.
7. **Focus and screen readers:** after a swap, focus moves to the new page's
   `[autofocus]`, else to `<main>` (made focusable), and the new title is
   announced through a polite live region the client adds.
8. **Feedback:** after 300 ms without an answer, `<html>` gets
   `data-monk-navigating` for the app's CSS (a progress bar, a dimmed pane).
   No built-in spinner.
9. **Events, no JS API** (as Live): `monk-navigate:start`, `:swapped`,
   `:fallback` (with the reason), `:failed`. An app moves to a page from its
   own code by dispatching `monk-navigate:visit` with `{ url }` on
   `document`. Without the client, nobody listens: the app checks
   `document.documentElement.dataset.monkNavigate` and uses
   `location.assign` otherwise.

## With Live

- After a swap, Live reconciles the topics (`reconcileTopics`, as after a
  resync): the same socket, only the difference subscribed or dropped.
- **The race:** a patch published between the server's render and the swap
  is lost. For a topic the page already had, Live queues patches that arrive
  while a navigation is in flight and applies them after the morph. For a
  topic the new page adds, nothing was subscribed at render time: Live
  resyncs once after the server acknowledges it, as on a reconnect (ADR
  0011's rule), so the page is correct. Cost: a second fetch on navigations
  that add topics. To measure in a real app (a chat list can follow ~100
  presence topics); a cheaper rule (the server telling, at subscribe,
  whether a topic was published to since a time the page carries) only if
  it matters.
- Live's resync refetches `location.href`, which is already the new URL
  after a swap. A resync and a navigation never run at once: the newer one
  wins, the other is dropped.
- A navigation to a page that isn't the app's (a login page after the
  session expired) is a full load, so Live stops there as today.

## The server

Nothing is required. Pages answer the same with or without the client, so
caches need no `Vary`. The client sends `Monk-Navigate: 1`, and
`request.navigate?` reads it, for logs only: a page must never answer
differently to it, or a reload would show something else.

## Testing

- The decisions (which click, which answer, whether `<head>` changed) in a
  pure module, tested under Node like `protocol.js`.
- A headless Chrome test in Monk's suite: navigate, back, forward, a
  fallback on 401 and on a changed asset, Live topics reconciled, a patch
  arriving mid-navigation.
- In apps: a check like an app's resync check script.

## Docs

An ADR (navigation is an opt-in refetch-and-morph, ADR 0011's operation for
another URL); `docs/guides/navigation.md`; a section in `live.md`; the
upgrading guide (how to turn it on, what an app's JS must do); the
scaffold's `agents.md` pitfalls; the roadmap.

## Out of scope for now

Prefetching on hover or touch, caching pages for back and forward, swapping
only a region (`<main>`, a frame), taking form submissions, the Navigation
API (where supported, it could replace click and `popstate` handling later),
view transitions.

## Open questions

0. Is it worth it at all? Weigh the client's size and the new rules an app's
   JS must follow (code that runs at load also runs on `:swapped`) against
   what it fixes; cheaper alternatives (the photo route with a long cache,
   view transitions across documents) may cover most of the "Why".
1. A module of its own (`Monk::Navigate`, `/_monk/navigate/`) or part of
   Live? First idea: its own client, so it works without Live, sharing
   Live's vendored idiomorph and morph options; Live listens to its events.
2. Where the setting lives: `Monk::Settings`, or `monk_head(navigate: true)`
   in the layout.
3. The new-topic resync: always, or only when measured to matter.
4. Should `monk add` turn it on for a new app, once it has been used for a
   while in a real app?

## What an app would change to adopt it (example, for reference)

- A connection banner becomes `data-monk-permanent`. Elements that are
  `data-live-ignore` only (a share box, photo boxes, a chat's "older" and
  "failed" markers) reset with each page, as they do today.
- `app.js`: what runs on `monk-live:resynced` (scroll the chat to the
  newest message, local times, mark read, retry avatars, a `?from=`
  anchor) runs on `monk-navigate:swapped` too. Elements found once at load
  (a welcome box, the banner) are looked up when used.
- `location.assign` after start, new chat and sign-in can stay full loads,
  or dispatch `monk-navigate:visit`. Photo save and remove keep
  `location.reload()`.
- A phone's detail pane (`data-view="detail"`) and its back link: Back is
  history, so it already works.
- Avatars: shown at once on pages that keep them; the photo route (bytes
  with a long cache) is still needed the first time a photo shows.
