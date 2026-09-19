// Monk::Live client runtime: subscribes to the topics a page declares with
// data-live-topic, applies the HTML patches the server pushes (morphing, so
// focus and typed text survive), and re-syncs by refetching the page when it
// may have missed something (ADR 0007, 0011). No JS API: it reports what it
// does through `monk-live:*` DOM events on `document`.
//
//   <meta name="monk-live-url" content="ws://localhost:9293">
//   <script type="module" src="/js/monk_live.js"></script>
//
// The decision logic lives in protocol.js, tested under plain Node.

import { Idiomorph } from "./idiomorph.js";
import {
  INITIAL_DELAY, nextDelay, topicsFrom, diffTopics, subscribeMessage, unsubscribeMessage, parseMessage, checkSeq,
} from "./protocol.js";

const emit = (name, detail = {}) => document.dispatchEvent(new CustomEvent(`monk-live:${name}`, { detail }));

// Focus and typed text: idiomorph keeps the focused element (and, with
// ignoreActiveValue, its value/selection). On top of that:
//  - [data-live-ignore] subtrees are left exactly as the client has them;
//  - <details open> is client state the server never sends, so a patch
//    doesn't close what the user opened.
const morphOptions = (morphStyle) => ({
  morphStyle,
  ignoreActiveValue: true,
  callbacks: {
    beforeNodeMorphed: (from) => !(from.nodeType === 1 && from.hasAttribute("data-live-ignore")),
    beforeAttributeUpdated: (name, node) => !(node.tagName === "DETAILS" && name === "open"),
  },
});

const currentTopics = () =>
  topicsFrom([...document.querySelectorAll("[data-live-topic]")].map((el) => el.getAttribute("data-live-topic")));

let url;
let socket;
let delay = INITIAL_DELAY;
let lastSeq = 0;
let subscribed = [];
let everConnected = false;
let needsResync = false;
let resyncing = false;
let resyncAgain = false;
let stopped = false;

function applyOp({ target, mode, html }) {
  let nodes;
  try {
    nodes = [...document.querySelectorAll(target)];
  } catch {
    console.warn(`monk-live: invalid selector ${JSON.stringify(target)}`);
    return;
  }
  const live = nodes.filter((node) => !node.closest("[data-live-ignore]"));

  for (const node of live) {
    switch (mode) {
      case "morph": Idiomorph.morph(node, html, morphOptions("outerHTML")); break;
      case "replace": node.outerHTML = html; break;
      case "append": node.insertAdjacentHTML("beforeend", html); break;
      case "prepend": node.insertAdjacentHTML("afterbegin", html); break;
      case "remove": node.remove(); break;
    }
  }
  emit("patched", { target, mode, matched: live.length });
}

function onMessage(event) {
  const message = parseMessage(event.data);

  switch (message.kind) {
    case "envelope": {
      const verdict = checkSeq(lastSeq, message.seq);
      lastSeq = message.seq;
      message.ops.forEach(applyOp);
      if (verdict === "gap") {
        emit("gap", { seq: message.seq });
        resync();
      }
      break;
    }
    case "subscribed":
      subscribed = [...new Set([...subscribed, ...message.topics])].sort();
      if (message.denied.length) console.warn("monk-live: subscription denied for", message.denied);
      emit("subscribed", { topics: message.topics, denied: message.denied });
      if (needsResync) resync();
      break;
    case "unsubscribed":
      subscribed = subscribed.filter((topic) => !message.topics.includes(topic));
      break;
    case "error":
      console.warn("monk-live: server error", message.reason);
      break;
    default:
      break;
  }
}

function stop(reason) {
  stopped = true;
  needsResync = false;
  socket?.close();
  emit("stopped", { reason });
}

// The page's own view is the only definition of what a region looks like
// (ADR 0011): refetch it and morph it in. If what comes back isn't the app
// page (an error, a redirect to a login screen), stop instead of morphing.
async function resync() {
  if (resyncing) {
    resyncAgain = true;
    return;
  }
  resyncing = true;
  try {
    const response = await fetch(location.href, {
      credentials: "same-origin", cache: "no-store", headers: { Accept: "text/html" },
    });
    const isHtml = (response.headers.get("content-type") || "").includes("text/html");
    if (!response.ok || response.redirected || !isHtml) {
      stop(response.redirected ? "redirected" : `status_${response.status}`);
      return;
    }
    const page = new DOMParser().parseFromString(await response.text(), "text/html");
    Idiomorph.morph(document.body, page.body, morphOptions("innerHTML"));
    needsResync = false;
    reconcileTopics();
    emit("resynced");
  } catch (error) {
    needsResync = true;
    console.warn("monk-live: resync failed", error);
    emit("resync-failed");
  } finally {
    resyncing = false;
    if (resyncAgain && !stopped) {
      resyncAgain = false;
      resync();
    }
  }
}

// A resync can bring new (or drop old) data-live-topic regions.
function reconcileTopics() {
  if (socket?.readyState !== WebSocket.OPEN) return;
  const { add, remove } = diffTopics(subscribed, currentTopics());
  if (add.length) socket.send(subscribeMessage(add));
  if (remove.length) socket.send(unsubscribeMessage(remove));
}

function connect() {
  socket = new WebSocket(url);
  socket.onopen = () => {
    delay = INITIAL_DELAY;
    lastSeq = 0;
    subscribed = [];
    // Patches may have been missed while we were away: resync once the
    // server has acknowledged our subscriptions (not before, or a patch
    // published between the fetch and the subscribe would be lost).
    needsResync = everConnected;
    everConnected = true;
    socket.send(subscribeMessage(currentTopics()));
    emit("connected");
  };
  socket.onmessage = onMessage;
  socket.onclose = () => {
    emit("disconnected");
    if (stopped) return;
    setTimeout(connect, delay);
    delay = nextDelay(delay);
  };
}

function start() {
  url = document.querySelector('meta[name="monk-live-url"]')?.content;
  if (!url) {
    console.error('monk-live: add <meta name="monk-live-url" content="ws://..."> to the page');
    return;
  }
  if (currentTopics().length === 0) return;
  connect();
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
else start();
