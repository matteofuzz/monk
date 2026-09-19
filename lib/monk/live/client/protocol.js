// Pure logic for the Monk::Live client: no DOM, no WebSocket, no globals, so
// it runs under plain `node --test` (test/js/protocol.test.js). The browser
// glue that uses it is monk_live.js.

export const INITIAL_DELAY = 500;
export const MAX_DELAY = 30000;

// Reconnect backoff: double, capped.
export const nextDelay = (delay) => Math.min(delay * 2, MAX_DELAY);

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
