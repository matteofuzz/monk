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

// The worker sees every window of the site alike, browser tabs and the
// installed app's windows. So each page running as the installed app says
// so (Monk's register.js posts { monkPwa: { standalone: true } }), and the
// worker keeps that per window, with a mark that the app is installed on
// this device. In the Cache API, not in memory: the browser stops the
// worker between events. The keys are never fetched.
const APP_WINDOWS = "monk-pwa-app-windows";
const INSTALLED = "/_monk/pwa/installed";
const APP_WINDOW = "/_monk/pwa/app-window/";

self.addEventListener("message", (event) => {
  if (event.data?.monkPwa?.standalone !== true || !event.source?.id) return;
  event.waitUntil(rememberAppWindow(event.source.id));
});

async function rememberAppWindow(id) {
  const cache = await caches.open(APP_WINDOWS);
  await cache.put(INSTALLED, new Response(""));
  await cache.put(APP_WINDOW + encodeURIComponent(id), new Response(""));
  // Forget the windows closed since.
  const open = new Set((await windowClients()).map((client) => client.id));
  for (const request of await cache.keys()) {
    const path = new URL(request.url).pathname;
    if (path.startsWith(APP_WINDOW) && !open.has(decodeURIComponent(path.slice(APP_WINDOW.length)))) {
      await cache.delete(request);
    }
  }
}

async function appWindows() {
  const cache = await caches.open(APP_WINDOWS);
  const ids = new Set();
  let installed = false;
  for (const request of await cache.keys()) {
    const path = new URL(request.url).pathname;
    if (path === INSTALLED) installed = true;
    if (path.startsWith(APP_WINDOW)) ids.add(decodeURIComponent(path.slice(APP_WINDOW.length)));
  }
  return { ids, installed };
}

const windowClients = () => self.clients.matchAll({ type: "window", includeUncontrolled: true });

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  // Only this app's own pages, whatever the message said.
  let url = new URL(event.notification.data?.url || "/", self.location.origin);
  if (url.origin !== self.location.origin) url = new URL("/", self.location.origin);

  // In the installed app when it's installed here, never a browser tab
  // left from before: an app window comes forward, or a new one opens (the
  // browser opens the app's own pages in the app). Otherwise a tab. Either
  // way, a window already on that page comes forward; otherwise an open
  // one goes there (one window follows the notifications, as in a
  // messaging app), and a new one opens only when none is.
  event.waitUntil((async () => {
    const windows = await windowClients();
    const app = await appWindows();
    const apps = windows.filter((client) => app.ids.has(client.id));
    if (apps.length > 0) return show(apps, url);
    if (app.installed) return self.clients.openWindow(url.href);
    return show(windows, url);
  })());
});

async function show(windows, url) {
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
}
