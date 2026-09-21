import { test } from "node:test";
import assert from "node:assert/strict";
import {
  INITIAL_DELAY, MAX_DELAY, nextDelay, topicsFrom, diffTopics,
  subscribeMessage, unsubscribeMessage, parseMessage, checkSeq, resyncVerdict,
} from "../../lib/monk/live/client/protocol.js";

test("nextDelay doubles from the initial delay and caps at 30s", () => {
  assert.equal(INITIAL_DELAY, 500);
  assert.equal(nextDelay(500), 1000);
  assert.equal(nextDelay(16000), MAX_DELAY);
  assert.equal(nextDelay(MAX_DELAY), MAX_DELAY);
});

test("topicsFrom splits on whitespace, dedupes and sorts", () => {
  assert.deepEqual(topicsFrom(["b:1 a:1", "a:1", "  c:2  "]), ["a:1", "b:1", "c:2"]);
  assert.deepEqual(topicsFrom([]), []);
  assert.deepEqual(topicsFrom([null, undefined, ""]), []);
});

test("diffTopics returns what to add and what to remove", () => {
  assert.deepEqual(diffTopics(["a", "b"], ["b", "c"]), { add: ["c"], remove: ["a"] });
  assert.deepEqual(diffTopics([], ["a"]), { add: ["a"], remove: [] });
  assert.deepEqual(diffTopics(["a"], ["a"]), { add: [], remove: [] });
});

test("subscribe and unsubscribe messages match the server protocol", () => {
  assert.deepEqual(JSON.parse(subscribeMessage(["a:1"])), { op: "subscribe", topics: ["a:1"] });
  assert.deepEqual(JSON.parse(unsubscribeMessage(["a:1"])), { op: "unsubscribe", topics: ["a:1"] });
});

test("a patch envelope parses to one op with its seq", () => {
  const text = JSON.stringify({ seq: 3, op: "patch", target: "#a", mode: "morph", html: "<i>x</i>" });

  assert.deepEqual(parseMessage(text), {
    kind: "envelope", seq: 3, ops: [{ target: "#a", mode: "morph", html: "<i>x</i>" }],
  });
});

test("a remove patch has no html", () => {
  const text = JSON.stringify({ seq: 1, op: "patch", target: "#a", mode: "remove" });

  assert.deepEqual(parseMessage(text).ops, [{ target: "#a", mode: "remove", html: undefined }]);
});

test("a batch flattens to its ops in order", () => {
  const text = JSON.stringify({
    seq: 2, op: "batch", ops: [
      { op: "patch", target: "#a", mode: "morph", html: "1" },
      { op: "patch", target: "#b", mode: "remove" },
    ],
  });

  const parsed = parseMessage(text);

  assert.equal(parsed.kind, "envelope");
  assert.deepEqual(parsed.ops.map((op) => op.target), ["#a", "#b"]);
});

test("control replies parse to their kinds", () => {
  assert.deepEqual(parseMessage('{"op":"subscribed","topics":["a"],"denied":["b"]}'),
    { kind: "subscribed", topics: ["a"], denied: ["b"] });
  assert.deepEqual(parseMessage('{"op":"unsubscribed","topics":["a"]}'), { kind: "unsubscribed", topics: ["a"] });
  assert.deepEqual(parseMessage('{"op":"error","reason":"bad_message"}'), { kind: "error", reason: "bad_message" });
});

test("anything malformed is invalid, never thrown", () => {
  const bad = [
    "not json", "123", "[]", "null", '{"op":"patch"}', '{"seq":1,"op":"patch","target":"#a","mode":"explode","html":"x"}',
    '{"seq":1,"op":"patch","target":"","mode":"morph","html":"x"}', '{"seq":1,"op":"patch","target":"#a","mode":"morph"}',
    '{"seq":"1","op":"patch","target":"#a","mode":"remove"}', '{"seq":1,"op":"batch","ops":[]}',
    '{"seq":1,"op":"batch","ops":[{"op":"patch","target":"#a","mode":"morph"}]}',
  ];

  for (const text of bad) assert.deepEqual(parseMessage(text), { kind: "invalid" }, text);
});

test("an unknown op is reported as unknown, not invalid", () => {
  assert.deepEqual(parseMessage('{"op":"dance"}'), { kind: "unknown", op: "dance" });
});

test("checkSeq accepts only the next number", () => {
  assert.equal(checkSeq(0, 1), "ok");
  assert.equal(checkSeq(4, 5), "ok");
  assert.equal(checkSeq(4, 6), "gap");
  assert.equal(checkSeq(4, 4), "gap");
  assert.equal(checkSeq(4, 1), "gap");
});

test("resyncVerdict accepts only an ok, un-redirected HTML response", () => {
  const ok = { ok: true, redirected: false, status: 200, contentType: "text/html; charset=utf-8" };

  assert.equal(resyncVerdict(ok), null);
  assert.equal(resyncVerdict({ ...ok, redirected: true }), "redirected");
  assert.equal(resyncVerdict({ ...ok, ok: false, status: 401 }), "status_401");
  assert.equal(resyncVerdict({ ...ok, ok: false, status: 500 }), "status_500");
  assert.equal(resyncVerdict({ ...ok, contentType: "application/json" }), "not_html");
  assert.equal(resyncVerdict({ ...ok, contentType: null }), "not_html");
});

test("a redirect is reported as redirected even when the login page answers 200", () => {
  assert.equal(resyncVerdict({ ok: true, redirected: true, status: 200, contentType: "text/html" }), "redirected");
});
