// Monk::Pwa: registers the app's service worker, /sw.js, for the whole
// site. Loaded by the layout's <%= monk_head %> when config/pwa.rb has run.
// No JS API, like Monk::Live: what happens is reported as `monk-pwa:*`
// events on `document`:
//   monk-pwa:registered  { scope }
//   monk-pwa:unsupported { reason: "no-service-worker" | "insecure" }
//   monk-pwa:failed      { message }
//
// updateViaCache: "none" makes the browser check /sw.js itself on every
// navigation, never from its HTTP cache, so an edited worker is picked up
// on the next page load.

const emit = (name, detail = {}) => document.dispatchEvent(new CustomEvent(`monk-pwa:${name}`, { detail }));

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

function tellWorkerThisIsTheApp() {
  navigator.serviceWorker.ready
    .then((registration) => registration.active?.postMessage({ monkPwa: { standalone: true } }))
    .catch((error) => console.warn("monk-pwa: telling /sw.js this is the app failed", error));
}
