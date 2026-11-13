// Monk::Push client: the decisions, without the browser, so Node can test
// them (test/js/push_state.test.js). push.js does the browser calls.

// What the page can show, from what the browser offers and what the
// person chose:
//   unsupported    no service worker or Push API (or not https)
//   needs-install  iOS in a browser tab: push only reaches a Home Screen app
//   denied         notifications blocked in the browser's settings
//   off            allowed or not yet asked, but not subscribed
//   subscribed     this browser gets notifications
export function pushState({ secure, serviceWorker, pushManager, notification, ios, standalone, permission, subscribed }) {
  if (ios && !standalone && !pushManager) return "needs-install";
  if (!secure || !serviceWorker || !pushManager || !notification) return "unsupported";
  if (permission === "denied") return "denied";
  if (permission === "granted" && subscribed) return "subscribed";
  return "off";
}

// Re-send (or make) the subscription on a page load only when the person
// already allowed notifications and didn't turn them off here: never asks
// for permission, which needs a click.
export function shouldResubscribe({ permission, optedOut }) {
  return permission === "granted" && !optedOut;
}

// base64url (the VAPID public key) to the bytes applicationServerKey takes.
export function keyBytes(base64url) {
  const base64 = base64url.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

// Whether a subscription was made with this key: after the app's VAPID
// keys change, an old subscription can't receive anything, so it's
// replaced.
export function sameKey(a, b) {
  if (!a || !b) return false;
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  return x.length === y.length && x.every((byte, i) => byte === y[i]);
}

// The csrf_token cookie Monk::Auth sets (not HttpOnly, for this), sent as
// X-CSRF-Token.
export function csrfToken(cookie) {
  for (const part of cookie.split(";")) {
    const [name, ...value] = part.trim().split("=");
    if (name === "csrf_token") return decodeURIComponent(value.join("="));
  }
  return null;
}

// iPhone and iPad, iPadOS included (it says Macintosh, with touch).
export function isIos(userAgent, maxTouchPoints) {
  return /iPad|iPhone|iPod/.test(userAgent) || (/Macintosh/.test(userAgent) && maxTouchPoints > 1);
}
