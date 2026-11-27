// Monk::Pwa's offline client: when the connection is gone, the page stays
// as it is (readable), <html> says so, the app's banner shows why, and
// links to the app's other pages are cancelled, since nothing could load.
// Loaded by <%= monk_head %> with register.js. Level 0 of
// docs/guides/offline.md; what the page does offline beyond that is the
// app's.
//
// No JS API, like Monk::Live. On <html>:
//   data-monk-offline        "network", "server" or "unreachable" while offline
//   data-monk-offline-nudge  for a moment after a blocked click (a CSS animation)
// Events on `document`:
//   monk-offline:offline { reason }   also when the reason changes
//   monk-offline:online  {}
// And one it listens to: an app whose own fetch failed dispatches
// `monk-offline:check` on document, and the page is checked.
//
// Offline means: no connection for OFFLINE_AFTER (2 s), then GET /_monk/up
// didn't get the app's answer. "network": the browser knows it's offline.
// "server": the proxy answered for an app that didn't (502/503/504, a
// deploy, a crash). "unreachable": no answer at all, which can't be told
// from a dead connection. Then /_monk/up is probed with backoff until the
// app answers; being shown again, the network or Live coming back probe
// at once.

import { OFFLINE_AFTER, FIRST_PROBE, nextProbe, jittered, probeReason, blocksClick } from "./offline_state.js";

const UP_PATH = "/_monk/up";
const PROBE_TIMEOUT = 5000;

const emit = (name, detail = {}) => document.dispatchEvent(new CustomEvent(`monk-offline:${name}`, { detail }));
const root = document.documentElement;

let reason = null; // null while online
let suspectTimer = null;
let probeTimer = null;
let probeDelay = FIRST_PROBE;
let probing = false;
let nudgeTimer = null;

// Something says the connection may be gone: look again in OFFLINE_AFTER,
// so a short drop shows nothing.
// Not while hidden: iOS drops a hidden page's socket within seconds, and
// nobody is looking; being shown again checks.
function suspect() {
  if (reason !== null || suspectTimer !== null || document.visibilityState === "hidden") return;
  suspectTimer = setTimeout(() => {
    suspectTimer = null;
    check();
  }, OFFLINE_AFTER);
}

// Something says the connection may be back: while offline, probe now.
function hopeful() {
  if (reason === null) return;
  clearTimeout(probeTimer);
  probeTimer = null;
  probeDelay = FIRST_PROBE;
  check();
}

async function check() {
  if (probing) return;
  probing = true;
  let found;
  try {
    found = await probe();
  } finally {
    probing = false;
  }
  if (found === null) {
    if (reason !== null) goOnline();
    return;
  }
  goOffline(found);
  clearTimeout(probeTimer);
  probeTimer = setTimeout(() => {
    probeTimer = null;
    check();
  }, jittered(probeDelay));
  probeDelay = nextProbe(probeDelay);
}

async function probe() {
  if (navigator.onLine === false) return "network";
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), PROBE_TIMEOUT);
  try {
    const response = await fetch(UP_PATH, { cache: "no-store", signal: controller.signal });
    return probeReason({ onLine: navigator.onLine, status: response.status });
  } catch {
    return probeReason({ onLine: navigator.onLine, networkError: true });
  } finally {
    clearTimeout(timeout);
  }
}

function goOffline(found) {
  if (found === reason) return;
  reason = found;
  root.dataset.monkOffline = reason;
  showBanners();
  emit("offline", { reason });
}

function goOnline() {
  reason = null;
  probeDelay = FIRST_PROBE;
  clearTimeout(probeTimer);
  probeTimer = null;
  delete root.dataset.monkOffline;
  showBanners();
  emit("online");
}

// <%= monk_offline %>: the banner, with the text for the reason.
function showBanners() {
  document.querySelectorAll("[data-monk-offline-banner]").forEach((banner) => {
    banner.hidden = reason === null;
    banner.querySelectorAll("[data-monk-offline-reason]").forEach((text) => {
      text.hidden = text.dataset.monkOfflineReason !== reason;
    });
  });
}

// Bubbling, so a click the app's own handler took (preventDefault) is left alone.
function onClick(event) {
  if (reason === null) return;
  const link = event.target.closest?.("a[href]");
  if (!link) return;
  const blocked = blocksClick({
    button: event.button, metaKey: event.metaKey, ctrlKey: event.ctrlKey, shiftKey: event.shiftKey,
    altKey: event.altKey, defaultPrevented: event.defaultPrevented, href: link.getAttribute("href"),
    target: link.getAttribute("target"), download: link.hasAttribute("download"),
    origin: location.origin, current: location.href,
  });
  if (!blocked) return;
  event.preventDefault();
  nudge();
}

// Removed and set again on the next frame, so a CSS animation restarts.
function nudge() {
  clearTimeout(nudgeTimer);
  delete root.dataset.monkOfflineNudge;
  requestAnimationFrame(() => {
    root.dataset.monkOfflineNudge = "";
    nudgeTimer = setTimeout(() => delete root.dataset.monkOfflineNudge, 1000);
  });
}

addEventListener("offline", suspect);
addEventListener("online", hopeful);
document.addEventListener("monk-live:disconnected", suspect);
document.addEventListener("monk-live:connected", hopeful);
document.addEventListener("monk-offline:check", () => (reason === null ? suspect() : hopeful()));
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible") return;
  if (reason === null && navigator.onLine === false) suspect();
  hopeful();
});
addEventListener("pageshow", (event) => {
  if (event.persisted) hopeful();
});
document.addEventListener("click", onClick);

if (navigator.onLine === false) suspect();
