# Proposal: offline, without an API and an SPA

Status: settled 2026-11-27, after discussion. **Monk ships level 0 only**
(below), plus guidance, documentation and two small helpers to decide in
the plan. Everything beyond it is the app's. Next: a plan
(`docs/plan-offline.md`) and an ADR. Related:
[`history/proposal-navigate.md`](history/proposal-navigate.md) (not pursued; independent of this one).

## Why

An installed app (`Monk::Pwa`) that loses the network today shows the
system's error page on launch or reload, and gives no sign of being offline
while a page is open. Every installable app needs a baseline: the page stays,
a banner says it's offline, and nothing pretends to work.

An app that wants more (a chat app meant to be someone's main one: the chat
list readable offline, messages written offline and sent later) builds it on
top, in its own code, with Monk's guide. Monk adopts a piece of that only
once an app has proven it generic.

## Four levels of offline, and who owns each

| Level | What a person can do offline | Owner |
|---|---|---|
| 0. Know it | see the page they had, frozen, and a clear "offline" | **Monk** |
| 1. Read | open a page they've seen (e.g. the chat list as last seen) | the app, with Monk's guide |
| 2. Act, send later | write (a message, a change), sent when back online | the app, with Monk's guide |
| 3. Work offline | browse, search and edit data no page has shown, merge conflicts | out of scope: needs an SPA or a sync layer |

## Level 0: what Monk ships

As a person, the expectation is: the page I'm on stays as it is, a banner
says I'm offline, and nothing pretends to work.

1. **Detecting offline.** `navigator.onLine` alone lies (it stays true on a
   captive portal or a connection where nothing comes back). Combined with
   Live's `monk-live:disconnected` / `monk-live:connected` (they exist
   today) and with failed `fetch`es the client sees. Without Live: the
   `online`/`offline` events and failed fetches.
   **No network or no server?** Different states, different messages:
   - `navigator.onLine` false: no network, for sure ("You're offline");
   - an answer of 502, 503 or 504 (the proxy answered, the app didn't, e.g.
     during a deploy or an outage): the server ("Can't reach the server,
     retrying");
   - a fetch that fails while `navigator.onLine` is true: **can't be told
     apart** (a dead connection, or the whole host gone). A probe to the
     app's own server doesn't help: it fails the same way. Only an outside
     endpoint could tell, and every client calling a third party is a
     privacy cost Monk doesn't take. Said honestly: "Can't connect".

   Monk sets `data-monk-offline="network"`, `"server"` or `"unreachable"`
   on `<html>` and passes the reason in its events.
2. **Not on every blip.** The offline state starts only after about 2 s
   without a connection, so a deploy (Live reconnects every page) or a
   short drop doesn't flash the banner.
3. **A banner, not an overlay.** "Frozen" means readable: the page stays
   as it was, nothing is hidden. The app's CSS styles `data-monk-offline`;
   a `<%= monk_offline %>` helper renders a banner (BEM classes, no
   styles, every text overridable), like `<%= monk_install %>`.
4. **Navigation blocked.** While offline, a click on a same-origin link is
   cancelled and the banner pulses (`data-monk-offline-nudge` for a CSS
   animation). Back can't be cancelled; point 5 covers it.
5. **Launching or reloading offline.** A frozen page only exists if a page
   is open, and iOS often kills an installed app in the background, so
   opening it offline is the common case, not an edge one. The scaffolded
   `sw.js` gets a `fetch` handler for page loads only (`mode:
   "navigate"`): network as today, and on a network failure (or a
   502/503/504) a precached `/offline.html`, which retries on `online` and
   from a button. Every other request is left alone, as today: the worker
   still never answers Live's resync, a redirect or `/_monk/`.
   `offline.html` is scaffolded static and generic (no user data, so
   nothing private can leak), and is the app's file from then on: an app
   may grow it into a personalized cached page of its own (level 1),
   following the guide's rules.
6. **Writes are the app's.** Its `fetch` posts fail and it shows the error,
   as today. CSS can disable buttons marked `[data-monk-online-only]`
   under `data-monk-offline`.
7. **Back online.** The attribute and the banner go. With Live, its resync
   brings the page up to date; without Live, nothing more.
8. **Knowing when it's back: `/_monk/up`.** While offline, the client (and
   `offline.html`) checks `GET /_monk/up` to know when to come back,
   which matters most without Live (with Live, its socket and heartbeat
   already tell). The route:
   - answers `204`, no body: no database, no session, not logged,
     `Cache-Control: no-store`, never answered by the service worker;
   - means "the process is alive", nothing more. A deep check (database,
     Redis) is a different route for whoever needs it: mixing them would
     show clients "offline" when only the database is slow;
   - is probed only while offline, with backoff and jitter, so after an
     outage every client doesn't hit the server at the same instant;
   - doubles as the **deploy health check** Monk lacks today (Caddy,
     compose, Fly have nothing to call), as Rails' `/up`. That dual use is
     its justification: a health route and a retry signal, **not** a
     network-vs-server diagnostic.

**Events,** as Live: `monk-offline:offline` (with the reason) and
`monk-offline:online` on `document`.

**On by default** in `monk add pwa`. Independent of
[Navigate](history/proposal-navigate.md), which is not pursued.

**Weight:** about 100 lines of JS, the worker's navigation fallback (about
20 lines), about 5 lines of Ruby for `/_monk/up`, the `monk_offline`
helper, the `offline.html` template. Nothing in it is chat-specific.

## Helpers to decide in the plan

Small and generic, for an app that grows its offline page into a cached one
(level 1). In or out is the plan's call:

- **Store and answer one page safely,** in the worker: only a 200 HTML GET
  from the same origin, never a redirect, Live's resync or `/_monk/`.
- **Clearing on sign-out:** a `Clear-Site-Data: "cache", "storage"`
  header on the logout response (Safari's support to check), and
  `register.js` telling the worker to delete its caches. Any app that
  caches a page with user data needs it.

## Guidance and documentation

- **`docs/guides/offline.md`** (or a section in `pwa.md`):
  - level 0: what Monk does, styling the banner, the events;
  - **growing the offline page (level 1, the app's):** caching a
    personalized page (the chat list as last seen) and its rules:
    private data and clearing it on sign-out, assets of an older deploy
    (cache them too, or treat the page as missing), bounds on number and
    size (images in their own cache), never caching Live's resync,
    redirects or `/_monk/`; Live's resync corrects a stale page once back
    online; Safari may evict storage of a site not visited for about 7
    days (installed apps reportedly exempt, to check);
  - **send later (level 2, the app's):** the outbox pattern (IndexedDB, a
    client-made id, pending state in the page, replay on `online`,
    `visibilitychange` and load, one at a time, in order; no Background
    Sync on iOS) and its server rule: **idempotency by the client's id**
    with a unique index, so a replay is a no-op;
  - level 3 is out of scope, said so.
- `deploying.md`: `/_monk/up` as the health check.
- The scaffold's `agents.md` pitfalls; the upgrading guide (adding the
  fetch handler, `offline.html` and the banner to an existing app).
- An ADR: "the service worker answers page loads only when the network
  failed, with the app's offline page; nothing else goes through it".

## Details left for the plan

- The client in `register.js` or its own file.
- The event names, and whether the 2 s delay is fixed or a setting.
- `offline.html` scaffolded (proposed: yes, the app's file) or served by
  the gem with the manifest's colours and name.
- The two helpers above.

## Testing

- **In Monk:** go offline with a page open (banner after the delay, link
  clicks blocked, back online clears it); launch and reload offline
  (`offline.html`, then back once online); a short drop shows no banner;
  a 502 shows "server"; `/_monk/up` answers 204 without touching the
  database, and is never served from the worker.
- **In an app that builds levels 1 and 2:** its own checks (sign out and
  the caches are gone; a message written offline arrives once).
