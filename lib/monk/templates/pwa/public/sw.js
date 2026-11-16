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

// Web push (monk add push): each message becomes a notification, and a
// click on one opens its page. Nothing arrives until push is set up and
// someone turns notifications on, so these do nothing before that.
//
// A message is the JSON an app sends with Monk::Push.notify:
// { title, body, url, tag } (tag: a newer notification with the same tag
// replaces the older one). Always show one: iOS and Chrome penalise a push
// that shows nothing, and iOS stops delivering after a few.
self.addEventListener("push", (event) => {
  let message = {};
  try {
    message = event.data ? event.data.json() : {};
  } catch {
    message = { body: event.data.text() };
  }
  event.waitUntil(
    self.registration.showNotification(message.title || "New notification", {
      body: message.body,
      tag: message.tag,
      icon: "/icons/icon-192.png",
      data: { url: message.url || "/" },
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  // Only this app's own pages, whatever the message said.
  let url = new URL(event.notification.data?.url || "/", self.location.origin);
  if (url.origin !== self.location.origin) url = new URL("/", self.location.origin);

  // A window already on that page comes forward; otherwise the app's open
  // window goes there (one window follows the notifications, as in a
  // messaging app), and a new one opens only when none is.
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const exact = windows.find((client) => client.url === url.href);
    if (exact) return exact.focus();
    try {
      if (windows[0]) {
        const focused = await windows[0].focus();
        if (await focused.navigate(url.href)) return;
      }
    } catch {
      // A window this worker doesn't control can't be navigated.
    }
    return self.clients.openWindow(url.href);
  })());
});
