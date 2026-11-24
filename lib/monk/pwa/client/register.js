// Monk::Pwa: registers the app's service worker, /sw.js, for the whole
// site. Loaded by the layout's <%= monk_head %> when config/pwa.rb has run.
// No JS API, like Monk::Live: what happens is reported as `monk-pwa:*`
// events on `document`:
//   monk-pwa:registered  { scope }
//   monk-pwa:unsupported { reason: "no-service-worker" | "insecure" }
//   monk-pwa:failed      { message }
//   monk-pwa:own-session { status }
//   monk-pwa:installable {}   the browser offered to install the app
//   monk-pwa:installed   {}
//
// And where it runs, on <html>, for CSS to show the right thing:
//   data-pwa-standalone  "true" in the installed app, "false" in a tab
//   data-pwa-platform    "ios", "android" or "other"
//   data-pwa-installable present once the browser offered to install
//   data-pwa-in-app      present in a chat or social app's built-in browser
// <%= monk_install %>'s banner is shown on iOS, or on Android once
// installable, and never in the app nor on a desktop; its button opens the browser's prompt, or on iOS the
// sheet saying how to Add to Home Screen.
//
// updateViaCache: "none" makes the browser check /sw.js itself on every
// navigation, never from its HTTP cache, so an edited worker is picked up
// on the next page load.
//
// With auth, the installed app on an iPhone also asks once for its own
// session (Monk::Auth's own_session!, at the meta's URL): Add to Home
// Screen copies Safari's cookies, so the app starts with Safari's very
// session, and logging out in one would end both.

import { platform, inApp, showInstall } from "./platform.js";

const emit = (name, detail = {}) => document.dispatchEvent(new CustomEvent(`monk-pwa:${name}`, { detail }));

const root = document.documentElement;
root.dataset.pwaStandalone = String(standalone());
root.dataset.pwaPlatform = platform(navigator.userAgent, navigator.maxTouchPoints);
if (inApp(navigator.userAgent)) root.dataset.pwaInApp = "";

// Chrome's own install prompt, kept for the banner's button.
let installPrompt = null;
addEventListener("beforeinstallprompt", (event) => {
  event.preventDefault();
  installPrompt = event;
  root.dataset.pwaInstallable = "";
  showBanners();
  emit("installable");
});
addEventListener("appinstalled", () => {
  installPrompt = null;
  delete root.dataset.pwaInstallable;
  showBanners();
  emit("installed");
});
document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-monk-install]");
  if (button) install(button);
});
showBanners();

ownSession();

if (!window.isSecureContext) {
  // Service workers need https, or localhost: a phone opening the dev
  // server at http://192.168.x.x gets none.
  console.warn("monk-pwa: not a secure context (https or localhost), so no service worker");
  emit("unsupported", { reason: "insecure" });
} else if (!("serviceWorker" in navigator)) {
  emit("unsupported", { reason: "no-service-worker" });
} else {
  navigator.serviceWorker
    .register("/sw.js", { scope: "/", updateViaCache: "none" })
    .then((registration) => {
      emit("registered", { scope: registration.scope });
      if (standalone()) tellWorkerThisIsTheApp();
    })
    .catch((error) => {
      console.warn("monk-pwa: registering /sw.js failed", error);
      emit("failed", { message: String(error?.message ?? error) });
    });
}

// Running as the installed app, not in a browser tab. The worker can't
// tell them apart, so a page in the app says so: sw.js then brings a
// notification's click to the app, not to a tab left open from before.
function standalone() {
  const modes = ["standalone", "fullscreen", "minimal-ui", "window-controls-overlay"];
  return navigator.standalone === true || modes.some((mode) => matchMedia(`(display-mode: ${mode})`).matches);
}

// navigator.standalone is iOS's alone: Android's installed app shares
// Chrome's cookies, so it has nothing to split. Remembered once the
// server answered (a 401 or 404 too: no session, or no route, to split),
// so a first launch offline tries again on the next one.
function ownSession() {
  const DONE = "monk-pwa:own-session";
  const url = document.querySelector('meta[name="monk-auth-own-url"]')?.content;
  if (!url || navigator.standalone !== true) return;
  try {
    if (localStorage.getItem(DONE) === "1") return;
  } catch {
    return; // no localStorage: it would ask on every launch
  }

  const csrf = document.cookie.split("; ").find((pair) => pair.startsWith("csrf_token="))?.slice("csrf_token=".length);
  fetch(url, { method: "POST", credentials: "same-origin", headers: csrf ? { "x-csrf-token": csrf } : {} })
    .then((response) => {
      if (!response.ok && response.status !== 401 && response.status !== 404) return;
      localStorage.setItem(DONE, "1");
      emit("own-session", { status: response.status });
    })
    .catch((error) => console.warn("monk-pwa: asking for the app's own session failed", error));
}

function showBanners() {
  const show = showInstall({
    platform: root.dataset.pwaPlatform,
    standalone: root.dataset.pwaStandalone === "true",
    installable: installPrompt !== null,
  });
  document.querySelectorAll("[data-monk-install-banner]").forEach((banner) => { banner.hidden = !show; });
}

// On iOS always the sheet: Add to Home Screen is the only way there.
function install(button) {
  if (installPrompt && root.dataset.pwaPlatform !== "ios") {
    const prompt = installPrompt;
    installPrompt = null;
    prompt.prompt();
    showBanners(); // Chrome's prompt is good for one go
    return;
  }
  const banner = button.closest("[data-monk-install-banner]");
  (banner ?? document).querySelector("[data-monk-install-sheet]")?.showModal();
}

function tellWorkerThisIsTheApp() {
  navigator.serviceWorker.ready
    .then((registration) => registration.active?.postMessage({ monkPwa: { standalone: true } }))
    .catch((error) => console.warn("monk-pwa: telling /sw.js this is the app failed", error));
}
