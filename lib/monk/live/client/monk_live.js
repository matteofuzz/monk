// Monk::Live client runtime: subscribes to the topics a page declares with
// data-live-topic, applies the HTML patches the server pushes (morphing, so
// focus and typed text survive), and re-syncs by refetching the page when it
// may have missed something (ADR 0007, 0011). No JS API: it reports what it
// does through `monk-live:*` DOM events on `document`.
//
// On real networks (docs/plan-live-networks-presence.md, A2-A3): while the
// page is visible it pings the server and gives up on a socket that doesn't
// answer (`stale`, then `disconnected` with reason "timeout"); it comes back
// at once when the page is shown again, the network returns, the page
// resumes or is restored from the back/forward cache; and it doesn't keep
// reconnecting while hidden or offline.
//
//   <meta name="monk-live-url" content="ws://localhost:9293">
//   <script type="module" src="/js/monk_live.js"></script>
//
// The decision logic lives in protocol.js, tested under plain Node.

import { Idiomorph } from "./idiomorph.js";
import {
  INITIAL_DELAY, HEARTBEAT, PONG_TIMEOUT, nextDelay, jittered, topicsFrom, diffTopics, subscribeMessage, unsubscribeMessage,
  pingMessage, hiddenMessage, parseMessage, checkSeq, resyncVerdict, reconnectDecision, returnAction,
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
let resyncRetryDelay = INITIAL_DELAY;
let resyncRetryTimer = null;
let stopped = false;
// Each connect() makes a new generation; events from an older socket (one
// given up on, whose onclose comes late) are ignored, so they can't
// schedule a second reconnect.
let generation = 0;
let reconnectTimer = null;
let heartbeatTimer = null;
let pongTimer = null;
// Reconnects tried since the page was last visible (reconnectDecision).
let hiddenAttempts = 0;

const isHidden = () => document.visibilityState === "hidden";
const isOpen = () => socket?.readyState === WebSocket.OPEN;
const reconnectState = () => ({ hidden: isHidden(), online: navigator.onLine !== false, hiddenAttempts });

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
    case "pong":
      break;
    default:
      break;
  }
}

function stop(reason) {
  stopped = true;
  needsResync = false;
  clearTimeout(resyncRetryTimer);
  clearTimeout(reconnectTimer);
  stopHeartbeat();
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
    const verdict = resyncVerdict({
      ok: response.ok, redirected: response.redirected, status: response.status,
      contentType: response.headers.get("content-type"),
    });
    if (verdict) {
      stop(verdict);
      return;
    }
    const page = new DOMParser().parseFromString(await response.text(), "text/html");
    Idiomorph.morph(document.body, page.body, morphOptions("innerHTML"));
    needsResync = false;
    resyncRetryDelay = INITIAL_DELAY;
    reconcileTopics();
    emit("resynced");
  } catch (error) {
    needsResync = true;
    console.warn("monk-live: resync failed", error);
    emit("resync-failed");
    scheduleResyncRetry();
  } finally {
    resyncing = false;
    if (resyncAgain && !stopped) {
      resyncAgain = false;
      resync();
    }
  }
}

// A failed refetch (network down, server restarting) is retried with the same
// backoff as reconnects, not only on the next reconnect or gap.
function scheduleResyncRetry() {
  if (resyncRetryTimer || stopped) return;
  resyncRetryTimer = setTimeout(() => {
    resyncRetryTimer = null;
    if (needsResync && !stopped) resync();
  }, resyncRetryDelay);
  resyncRetryDelay = nextDelay(resyncRetryDelay);
}

// A resync can bring new (or drop old) data-live-topic regions.
function reconcileTopics() {
  if (socket?.readyState !== WebSocket.OPEN) return;
  const { add, remove } = diffTopics(subscribed, currentTopics());
  if (add.length) socket.send(subscribeMessage(add));
  if (remove.length) socket.send(unsubscribeMessage(remove));
}

function connect() {
  clearTimeout(reconnectTimer);
  reconnectTimer = null;
  if (socket) retire({ reason: "closed" });
  if (isHidden()) hiddenAttempts += 1;
  const current = ++generation;
  socket = new WebSocket(url);
  socket.onopen = () => {
    if (current !== generation) return;
    delay = INITIAL_DELAY;
    lastSeq = 0;
    subscribed = [];
    // Patches may have been missed while we were away: resync once the
    // server has acknowledged our subscriptions (not before, or a patch
    // published between the fetch and the subscribe would be lost).
    needsResync = everConnected;
    everConnected = true;
    socket.send(subscribeMessage(currentTopics()));
    startHeartbeat();
    // Presence counts this socket as hidden until its first ping (ADR
    // 0019): a visible page pings now, so it reads as online at once.
    if (!isHidden()) ping();
    emit("connected");
  };
  socket.onmessage = (event) => {
    if (current !== generation) return;
    // Any frame shows the socket is alive, not only a pong.
    clearTimeout(pongTimer);
    pongTimer = null;
    onMessage(event);
  };
  socket.onclose = (event) => {
    if (current !== generation) return;
    lost({ reason: "closed", code: event.code });
  };
}

// The socket is gone, closed or given up on: report it once, then come back
// when reconnectDecision allows; otherwise a page event (visible, online)
// brings it back.
function lost(detail) {
  retire(detail);
  if (!stopped) scheduleReconnect();
}

function retire(detail) {
  generation += 1;
  const old = socket;
  socket = null;
  stopHeartbeat();
  old.onopen = old.onmessage = old.onclose = null;
  if (old.readyState <= WebSocket.OPEN) old.close();
  emit("disconnected", detail);
}

function scheduleReconnect() {
  if (reconnectTimer || reconnectDecision(reconnectState()) === "wait") return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    if (!stopped && !socket && reconnectDecision(reconnectState()) === "connect") connect();
  }, jittered(delay));
  delay = nextDelay(delay);
}

// The page came back: no waiting out the backoff, which may have reached
// 30 s. Still jittered, from the first step.
function connectSoon() {
  clearTimeout(reconnectTimer);
  reconnectTimer = null;
  delay = INITIAL_DELAY;
  scheduleReconnect();
}

// Only while visible: a hidden page's timers are throttled, and the server's
// own ping covers it.
function startHeartbeat() {
  stopHeartbeat();
  if (isHidden() || !isOpen()) return;
  heartbeatTimer = setInterval(ping, HEARTBEAT);
}

function stopHeartbeat() {
  clearInterval(heartbeatTimer);
  heartbeatTimer = null;
  clearTimeout(pongTimer);
  pongTimer = null;
}

// A network that went away under the socket can leave it "open" for minutes:
// no frame within PONG_TIMEOUT and it's given up on now, not when the
// browser gets round to onclose.
function ping() {
  if (!isOpen()) return;
  socket.send(pingMessage());
  pongTimer ??= setTimeout(() => {
    pongTimer = null;
    emit("stale");
    lost({ reason: "timeout" });
  }, PONG_TIMEOUT);
}

// Hidden: no more pings, and the server is told at once (presence's Away).
function goneHidden() {
  stopHeartbeat();
  if (isOpen()) socket.send(hiddenMessage());
}

// Visible again, online again, resumed: probe or reconnect at once, and
// retry a resync that failed while away.
function comeBack() {
  if (stopped) return;
  if (!isHidden()) hiddenAttempts = 0;
  switch (returnAction(socket?.readyState)) {
    case "probe":
      if (!isHidden()) {
        startHeartbeat();
        ping();
      }
      break;
    case "connect":
      if (socket) retire({ reason: "closed" });
      connectSoon();
      break;
  }
  if (needsResync && isOpen() && !resyncing) {
    clearTimeout(resyncRetryTimer);
    resyncRetryTimer = null;
    resync();
  }
}

function listen() {
  document.addEventListener("visibilitychange", () => (isHidden() ? goneHidden() : comeBack()));
  document.addEventListener("resume", comeBack);
  window.addEventListener("online", comeBack);
  // Nothing can get through: no reconnect loop until the network returns.
  window.addEventListener("offline", () => {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  });
  // Restored from the back/forward cache: the browser closed the socket
  // when the page went in, and its close event may not have come yet.
  window.addEventListener("pageshow", (event) => {
    if (!event.persisted || stopped) return;
    if (socket) retire({ reason: "restored" });
    comeBack();
  });
}

function start() {
  url = document.querySelector('meta[name="monk-live-url"]')?.content;
  if (!url) {
    console.error('monk-live: add <meta name="monk-live-url" content="ws://..."> to the page');
    return;
  }
  if (currentTopics().length === 0) return;
  listen();
  connect();
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
else start();
