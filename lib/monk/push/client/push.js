// Monk::Push client: lets a person turn notifications on and off, and
// keeps this browser's subscription stored on the server. Loaded by the
// layout's <%= monk_head %> when config/push.rb has run. No JS API, like
// Monk::Live: the page uses attributes, and hears events.
//
//   <button data-push-enable>Turn on notifications</button>
//   <button data-push-disable>Turn off</button>
//
// The state (see state.js) is set as <html data-push-state="...">, so CSS
// can show the right button, and reported as monk-push:state { state } on
// document; a failure as monk-push:error { message }.
//
// Every page load re-sends the subscription when notifications are
// allowed: that's how a rotated endpoint, or a row the server deleted,
// heals (docs/plan-pwa-push.md decision 8).

import { pushState, shouldResubscribe, keyBytes, sameKey, csrfToken, isIos } from "./state.js";

const meta = (name) => document.querySelector(`meta[name="${name}"]`)?.content;
const KEY = meta("monk-push-key");
const URL_PATH = meta("monk-push-url");
const OPTED_OUT = "monk-push:off";

const emit = (name, detail) => document.dispatchEvent(new CustomEvent(`monk-push:${name}`, { detail }));

const optedOut = () => {
  try { return localStorage.getItem(OPTED_OUT) === "1"; } catch { return false; }
};
const setOptedOut = (value) => {
  try { value ? localStorage.setItem(OPTED_OUT, "1") : localStorage.removeItem(OPTED_OUT); } catch { /* private mode */ }
};

const supported = () => window.isSecureContext && "serviceWorker" in navigator && "PushManager" in window &&
  "Notification" in window;

async function currentSubscription() {
  if (!supported()) return null;
  const registration = await navigator.serviceWorker.ready;
  return registration.pushManager.getSubscription();
}

async function report(subscription) {
  const state = pushState({
    secure: window.isSecureContext,
    serviceWorker: "serviceWorker" in navigator,
    pushManager: "PushManager" in window,
    notification: "Notification" in window,
    ios: isIos(navigator.userAgent, navigator.maxTouchPoints),
    standalone: window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true,
    permission: "Notification" in window ? Notification.permission : "default",
    subscribed: !!subscription,
  });
  document.documentElement.dataset.pushState = state;
  emit("state", { state });
}

function send(method, body) {
  const token = csrfToken(document.cookie);
  return fetch(URL_PATH, {
    method,
    credentials: "same-origin",
    headers: { "content-type": "application/json", ...(token ? { "x-csrf-token": token } : {}) },
    body: JSON.stringify(body),
  }).then((response) => {
    if (!response.ok) throw new Error(`${method} ${URL_PATH} answered ${response.status}`);
  });
}

// This browser's subscription for the app's current key, made if needed,
// and stored on the server.
async function subscribe() {
  const registration = await navigator.serviceWorker.ready;
  let subscription = await registration.pushManager.getSubscription();
  if (subscription && !sameKey(subscription.options?.applicationServerKey, keyBytes(KEY))) {
    await subscription.unsubscribe();
    subscription = null;
  }
  subscription ||= await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(KEY) });
  await send("POST", subscription.toJSON());
  return subscription;
}

async function enable() {
  try {
    // Called straight from the click: iOS only asks inside a user gesture.
    const permission = await Notification.requestPermission();
    if (permission !== "granted") return report(null);
    setOptedOut(false);
    report(await subscribe());
  } catch (error) {
    emit("error", { message: String(error?.message ?? error) });
    report(await currentSubscription().catch(() => null));
  }
}

async function disable() {
  try {
    setOptedOut(true);
    const subscription = await currentSubscription();
    if (subscription) {
      await send("DELETE", { endpoint: subscription.endpoint }).catch(() => {});
      await subscription.unsubscribe();
    }
  } catch (error) {
    emit("error", { message: String(error?.message ?? error) });
  }
  report(null);
}

document.addEventListener("click", (event) => {
  if (event.target.closest("[data-push-enable]")) enable();
  else if (event.target.closest("[data-push-disable]")) disable();
});

(async () => {
  if (!KEY || !URL_PATH || !supported()) return report(null);
  try {
    const permission = Notification.permission;
    report(shouldResubscribe({ permission, optedOut: optedOut() }) ? await subscribe() : await currentSubscription());
  } catch (error) {
    emit("error", { message: String(error?.message ?? error) });
    report(await currentSubscription().catch(() => null));
  }
})();
