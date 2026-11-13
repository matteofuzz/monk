// The app's service worker (monk add pwa). Served from /sw.js, so its
// scope is the whole site, and registered on every page by Monk's script,
// which the layout's <%= monk_head %> loads.
//
// No "fetch" handler, on purpose: every request goes to the network as if
// there were no service worker. So it never answers Monk::Live's resync
// (a refetch of the page) with a stale copy, never caches a login
// redirect, and never touches /_monk/ paths. An offline page or caching
// needs one: keep those requests out of it.
//
// An edited file is picked up on the next page load; these two make the
// new version take over open pages at once, rather than once they're all
// closed.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
