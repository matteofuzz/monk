// The app's service worker (monk add pwa). Served from /sw.js, so its
// scope is the whole site, and registered on every page by Monk's script,
// which the layout's <%= monk_head %> loads.
//
// It steps in for page loads only, and only when they fail: no network,
// or the proxy answering for an app that's down (502, 503, 504, during a
// deploy, say). Then it shows the app's public/offline.html instead of
// the browser's error. Every other request, and every answer that came,
// goes through untouched and is never stored: it never answers
// Monk::Live's resync (a fetch, not a page load) with a stale copy, never
// caches a login redirect, and never touches /_monk/ paths. Caching
// pages to read offline is the app's to add (docs/guides/offline.md):
// keep those requests out of it.
//
// An edited file is picked up on the next page load; skipWaiting and
// claim make the new version take over open pages at once, rather than
// once they're all closed.
// Code that deletes the caches it doesn't know keeps this one, and
// monk-pwa-app-windows below.
const OFFLINE_CACHE = "monk-offline";
const OFFLINE_PAGE = "/offline.html";

self.addEventListener("install", (event) => {
  // Offline while installing: still installs, and the next page load
  // stores the page.
  event.waitUntil(storeOfflinePage().catch(() => {}).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (event) => {
  // The page's request starts while the worker boots, not after.
  event.waitUntil(Promise.all([self.registration.navigationPreload?.enable(), self.clients.claim()]));
});

self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.mode !== "navigate" || request.method !== "GET") return;
  event.respondWith(pageLoad(event));
});

// The offline page is refreshed once per start of the worker, after a
// page load that worked: an edited offline.html shows from the next start.
let offlinePageStored = false;

async function pageLoad(event) {
  let response;
  try {
    response = (await event.preloadResponse) || (await fetch(event.request));
  } catch {
    return offlinePage(null);
  }
  if ([502, 503, 504].includes(response.status)) return offlinePage(response);
  if (!offlinePageStored) {
    offlinePageStored = true;
    event.waitUntil(storeOfflinePage().catch(() => { offlinePageStored = false; }));
  }
  return response;
}

async function storeOfflinePage() {
  const response = await fetch(OFFLINE_PAGE, { cache: "reload" });
  if (!response.ok) throw new Error(`${OFFLINE_PAGE}: ${response.status}`);
  await (await caches.open(OFFLINE_CACHE)).put(OFFLINE_PAGE, response);
}

// Answered for the URL that failed, so its "Try again" reloads that page.
// Without a stored copy: the proxy's answer, or the browser's error.
async function offlinePage(fallback) {
  const stored = await (await caches.open(OFFLINE_CACHE)).match(OFFLINE_PAGE);
  if (!stored) return fallback ?? Response.error();
  return new Response(stored.body, {
    status: 503,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
  });
}

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
