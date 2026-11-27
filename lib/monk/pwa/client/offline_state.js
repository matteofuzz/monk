// What offline.js decides, as pure functions (test/js/pwa_offline.test.js).

// How long a lost connection lasts before the page counts as offline: a
// deploy (Live reconnects every page) or a short drop shows nothing.
export const OFFLINE_AFTER = 2000;

// While offline, /_monk/up is probed from 1 s, doubling up to 30 s,
// jittered so pages don't all come back at the same instant.
export const FIRST_PROBE = 1000;
export const MAX_PROBE = 30000;

export const nextProbe = (delay) => Math.min(delay * 2, MAX_PROBE);
export const jittered = (delay, random = Math.random) => Math.round(delay * (0.5 + random() / 2));

// What a probe of /_monk/up says: null when the app answers (online),
// otherwise why not. The proxy answering 502/503/504 means the network is
// fine and the app isn't; no answer at all can't be told apart from a dead
// connection, so it's "unreachable", unless the browser itself knows it's
// offline.
export function probeReason({ onLine, networkError = false, status = null }) {
  if (onLine === false) return "network";
  if (networkError) return "unreachable";
  if (status === 502 || status === 503 || status === 504) return "server";
  return null;
}

// Whether a click on a link would leave the page for another of this
// app's: those are cancelled while offline, as nothing could load. A new
// tab or window, a download, another site, a link within this same page,
// or a click something else already handled is left to the browser.
export function blocksClick({ button, metaKey, ctrlKey, shiftKey, altKey, defaultPrevented, href, target, download,
                              origin, current }) {
  if (defaultPrevented || button !== 0 || metaKey || ctrlKey || shiftKey || altKey) return false;
  if (download || (target && target !== "_self")) return false;
  let url;
  try {
    url = new URL(href, current);
  } catch {
    return false;
  }
  if (url.origin !== origin) return false;
  const here = new URL(current);
  const samePage = url.pathname === here.pathname && url.search === here.search;
  return !(samePage && url.hash !== "");
}
