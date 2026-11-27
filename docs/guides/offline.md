# Offline

What an installable app ([`pwa.md`](pwa.md)) does when the network goes
away, what Monk does for it, and what is the app's to add.

"Offline" means four different things. Monk does the first; the next two
are patterns an app builds on it; the last is out of scope.

| Level | What a person can do offline | Who |
|---|---|---|
| 0. Know it | see the page they had, and a clear "offline" | Monk, with `monk add pwa` |
| 1. Read | open a page they've seen (a chat list as last seen) | the app ([below](#level-1-a-page-stored-for-offline)) |
| 2. Send later | write something that goes out once back online | the app ([below](#level-2-sending-later)) |
| 3. Work offline | browse, search and edit data no page has shown | out of scope: that's a client-side app with a sync layer |

## Level 0: what Monk does

`monk add pwa` turns it on; there's nothing else to wire.

**A page that's open stays as it is.** It's still readable, nothing
covers it. When the connection has been gone for 2 seconds (a deploy or a
short drop shows nothing), Monk's `/_monk/pwa/offline.js`, loaded by
`<%= monk_head %>`, checks `GET /_monk/up` and, if the app didn't answer,
sets `<html data-monk-offline="…">` with the reason:

| Reason | When | Default text |
|---|---|---|
| `network` | the browser knows it's offline | You’re offline. |
| `server` | the proxy answered for an app that didn't (502, 503, 504: a deploy, a crash) | Can’t reach the server, retrying… |
| `unreachable` | no answer at all, which can't be told from a dead connection | Can’t connect. |

It notices from `navigator.onLine` and its `offline` event, from Live's
socket closing (`monk-live:disconnected`), and from the app saying so (see
[Your own requests](#your-own-requests)). A hidden page doesn't check;
being shown again does.

**The banner.** `<%= monk_offline %>` in the layout renders a banner,
hidden until the page is offline, showing the text for the reason. It has
BEM classes (`monk-offline`, `__text`) and no styles, and
`role="status"` so screen readers announce it. Every text can be
overridden:

```erb
<%= monk_offline network: "Sei offline.", server: "Il server non risponde, riprovo…",
                 unreachable: "Impossibile connettersi." %>
```

Style the rest of the page from the attribute, a dimmed list say:

```css
.monk-offline { position: sticky; top: 0; padding: .5rem; background: #fef3c7; text-align: center; }
[data-monk-offline] main { opacity: .7; }
```

**Links don't lead anywhere.** While offline, a click on a link to another
of the app's pages is cancelled, and `<html>` gets
`data-monk-offline-nudge` for a second, for a CSS animation that draws the
eye to the banner:

```css
[data-monk-offline-nudge] .monk-offline { animation: nudge .3s; }
@keyframes nudge { 50% { transform: scale(1.03); } }
```

A link that opens a new tab, a download, another site, or a place on the
same page is left alone. So is a click your own code already handled
(`preventDefault`).

**Back online.** While offline, `/_monk/up` is checked again with backoff
(1 s, doubling to 30 s, jittered), and at once when the page is shown,
the browser goes back online, or Live reconnects. When the app answers,
the attribute and the banner go. With Live, its resync brings the page up
to date; without it, nothing changes on the page.

**Opening or reloading the app offline.** An installed app is often
closed by the phone in the background, so opening it offline is the
usual case, not an edge one. `public/sw.js` handles that: for page loads
only, when the load fails (no network, or 502/503/504), it answers with
the app's `public/offline.html`, stored when the worker installs.
`offline.html` tries again on its own and from its button, and reloads the
page that couldn't load once `/_monk/up` answers. Everything else (every
other request, every answer that came) goes through the worker untouched
and is never stored, so it never answers Live's resync with a stale copy
or replays a login redirect. `offline.html` is the app's file: change its
text and look. Keep it self-contained, with styles and script inline:
nothing else is stored for offline use. `Monk::Pwa.configure` fails the
boot if it's missing.

**Events,** on `document`: `monk-offline:offline` (`{ reason }`, again
when the reason changes) and `monk-offline:online`.

### Your own requests

A Monk app sends its forms and actions with `fetch`. When one fails with
a network error, tell Monk, and the page is checked:

```js
try {
  await fetch("/messages", { method: "POST", body });
} catch {
  document.dispatchEvent(new CustomEvent("monk-offline:check"));
  showError();
}
```

Buttons that only work online can be disabled with CSS while offline:

```css
[data-monk-offline] [data-monk-online-only] { pointer-events: none; opacity: .5; }
```

## `GET /_monk/up`

Every Monk app answers it, with or without pwa: `204`, no body,
`no-store`. It runs before routing, so no route, session or database is
involved, and it isn't logged. It means "the process answers requests",
nothing more: a slow database must not make pages read as offline. If you
need a deeper check (the database, Redis), write a route of your own for
it. It's also the deploy's health check
([`deploying.md`](deploying.md#4-a-single-vps-docker-compose--caddy)).

## Level 1: a page stored for offline

The app's to build, on its own `sw.js` and `offline.html`. The usual one:
instead of a generic "offline", show the last list the person saw (the
chat list, the inbox). A way to do it: after each page load of that list,
the page (or the worker) stores its HTML in a cache of the app's own, and
`offline.html` (or the worker's fallback) shows it, marked as old. The
rules, each learnt the hard way:

- **It holds one person's data.** Clear it when they sign out, or the next
  person on a shared device sees it: a `Clear-Site-Data: "cache",
  "storage"` header on the logout response (check the browsers you
  support), and the page telling the worker to delete its caches before
  the logout request.
- **Never store** Live's resync (it's a `fetch`, not a page load), a
  redirect (a login page would replay), anything but a `GET`, or a
  `/_monk/` path.
- **Assets change with deploys.** A stored page points at
  `asset_path`'s fingerprinted files of its deploy. Store those too (and
  drop old ones), or inline what the stored page needs.
- **Bound it.** A number of pages, or an age; images in their own cache,
  bounded, or not at all.
- **Keep Monk's caches** when cleaning up: `monk-offline` and
  `monk-pwa-app-windows`.
- **Back online, Live corrects it.** A stored page shown and then
  connected resyncs to the fresh one (ADR 0011).
- **Safari may evict** the storage of a site not visited for about seven
  days; installed apps are reported exempt. One more reason to help people
  install ([`pwa.md`](pwa.md#helping-people-install)).

## Level 2: sending later

Also the app's. Something written offline (a message) shows at once as
pending, and goes out once back online. An outbox, in the app's
JavaScript:

1. On submit, store the write in IndexedDB with an id the page makes
   (`crypto.randomUUID()`), and show it marked pending.
2. Send it. A network error leaves it stored (and dispatches
   `monk-offline:check`); a 4xx drops it and shows the error; a success
   removes it, and Live's patch replaces the pending element with the
   real one.
3. Send what's stored on `monk-offline:online`, when the page is shown
   again, and at page load, one at a time, in order. iOS has no Background
   Sync: stored writes go out once the app is open again.

**The server's part: idempotency.** The page's id travels with the write,
and the table stores it with a unique index. A write sent twice (the
answer was lost, not the request) is then a no-op that answers like the
first one, so nothing is ever saved twice. Keep stored writes independent
of each other (an edit to a message not yet sent is the hard case).

## Level 3

Data on the device, rendered by the page, merged with a sync engine: a
different kind of app. Monk doesn't go there; an app that needs it brings
its own layer.
