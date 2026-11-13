// Pure logic for the Monk::Live client: no DOM, no WebSocket, no globals, so
// it runs under plain `node --test` (test/js/protocol.test.js). The browser
// glue that uses it is monk_live.js.

export const INITIAL_DELAY = 500;
export const MAX_DELAY = 30000;

// The client's heartbeat (docs/plan-live-networks-presence.md, A2): while
// the page is visible, a Live ping every HEARTBEAT; no frame at all within
// PONG_TIMEOUT after one means the socket is dead, though the browser may
// not say so for minutes (a network that went away under it). Not sent
// while hidden: browsers throttle a hidden page's timers, so a timeout
// there would fire late and wrongly, and the server's own ping covers it.
export const HEARTBEAT = 25000;
export const PONG_TIMEOUT = 10000;

// Reconnect backoff: double, capped.
export const nextDelay = (delay) => Math.min(delay * 2, MAX_DELAY);

// The wait actually used: 50%..150% of the backoff delay. When the WS process
// restarts, every open page loses its socket at once; without jitter they all
// reconnect, and all refetch their page (resync), at the same instant.
export const jittered = (delay, random = Math.random) => Math.floor(delay * (0.5 + random()));

const MODES = ["morph", "replace", "append", "prepend", "remove"];

// data-live-topic values ("a:1 b:2") -> a sorted, de-duplicated topic list.
export function topicsFrom(values) {
  const topics = new Set();
  for (const value of values) {
    for (const topic of String(value ?? "").split(/\s+/)) if (topic) topics.add(topic);
  }
  return [...topics].sort();
}

export function diffTopics(current, wanted) {
  return {
    add: wanted.filter((topic) => !current.includes(topic)),
    remove: current.filter((topic) => !wanted.includes(topic)),
  };
}

export const subscribeMessage = (topics) => JSON.stringify({ op: "subscribe", topics });
export const unsubscribeMessage = (topics) => JSON.stringify({ op: "unsubscribe", topics });
export const pingMessage = () => JSON.stringify({ op: "ping" });
// Sent once as the page is hidden, so presence reads Away at once rather
// than after 2 x HEARTBEAT without a ping (which still covers a page
// frozen before this gets out).
export const hiddenMessage = () => JSON.stringify({ op: "hidden" });

// With no socket, whether to open one now or wait for the page to come back
// (visible, online). Offline, an attempt can't succeed. Hidden, one attempt
// is made: Android keeps a hidden page's socket, so a dropped one comes
// back without unlocking; iOS resets a socket opened by a hidden page
// within seconds, so after that one the page waits to be shown.
export function reconnectDecision({ hidden, online, hiddenAttempts }) {
  if (!online) return "wait";
  if (hidden && hiddenAttempts >= 1) return "wait";
  return "connect";
}

// The page came back (visible, online, resumed), given the socket's
// readyState (undefined without one): an open socket may be dead without
// knowing it, so it's probed with a ping; a connecting one is left alone;
// otherwise connect now.
export function returnAction(readyState) {
  if (readyState === 1) return "probe";
  if (readyState === 0) return "none";
  return "connect";
}

const isString = (value) => typeof value === "string";

function validOp(op) {
  if (op === null || typeof op !== "object" || op.op !== "patch") return false;
  if (!isString(op.target) || op.target.trim() === "" || !MODES.includes(op.mode)) return false;
  return op.mode === "remove" ? true : isString(op.html);
}

const toOp = ({ target, mode, html }) => ({ target, mode, html });

// One server frame -> { kind: "envelope" | "subscribed" | "unsubscribed" |
// "error" | "unknown" | "invalid", ... }. Never throws: a frame the client
// can't understand must not take the connection down.
export function parseMessage(text) {
  let message;
  try {
    message = JSON.parse(text);
  } catch {
    return { kind: "invalid" };
  }
  if (message === null || typeof message !== "object" || Array.isArray(message)) return { kind: "invalid" };

  switch (message.op) {
    case "patch":
      if (!Number.isInteger(message.seq) || !validOp(message)) return { kind: "invalid" };
      return { kind: "envelope", seq: message.seq, ops: [toOp(message)] };
    case "batch":
      if (!Number.isInteger(message.seq) || !Array.isArray(message.ops) || message.ops.length === 0) {
        return { kind: "invalid" };
      }
      if (!message.ops.every(validOp)) return { kind: "invalid" };
      return { kind: "envelope", seq: message.seq, ops: message.ops.map(toOp) };
    case "subscribed":
      return { kind: "subscribed", topics: message.topics ?? [], denied: message.denied ?? [] };
    case "unsubscribed":
      return { kind: "unsubscribed", topics: message.topics ?? [] };
    case "error":
      return { kind: "error", reason: message.reason };
    case "pong":
      return { kind: "pong" };
    default:
      return { kind: "unknown", op: message.op };
  }
}

// seq is per connection and starts at 1, so anything but last + 1 means a
// frame was missed, duplicated or reordered: resync.
export const checkSeq = (last, seq) => (seq === last + 1 ? "ok" : "gap");

// Whether a refetched page may be morphed in. null means yes; anything else
// is the reason to stop instead. A redirect is checked first: a redirect to a
// login screen usually answers 200 HTML, which would otherwise pass.
export function resyncVerdict({ ok, redirected, status, contentType }) {
  if (redirected) return "redirected";
  if (!ok) return `status_${status}`;
  if (!String(contentType ?? "").includes("text/html")) return "not_html";
  return null;
}
