import { test } from "node:test";
import assert from "node:assert/strict";
import {
  OFFLINE_AFTER, FIRST_PROBE, MAX_PROBE, nextProbe, jittered, probeReason, blocksClick,
} from "../../lib/monk/pwa/client/offline_state.js";

test("probeReason: the browser offline, no answer, the proxy without the app, the app", () => {
  assert.equal(probeReason({ onLine: false, networkError: true }), "network");
  assert.equal(probeReason({ onLine: false, status: 204 }), "network");
  assert.equal(probeReason({ onLine: true, networkError: true }), "unreachable");
  for (const status of [502, 503, 504]) assert.equal(probeReason({ onLine: true, status }), "server", String(status));
  assert.equal(probeReason({ onLine: true, status: 204 }), null);
  assert.equal(probeReason({ onLine: true, status: 404 }), null, "something answered: not offline");
  assert.equal(probeReason({ onLine: undefined, status: 204 }), null, "a browser without navigator.onLine");
});

test("the delays: 2 s before offline, probes from 1 s doubling to 30 s, jittered down to half", () => {
  assert.equal(OFFLINE_AFTER, 2000);
  assert.equal(nextProbe(FIRST_PROBE), 2000);
  assert.equal(nextProbe(20000), MAX_PROBE);
  assert.equal(nextProbe(MAX_PROBE), MAX_PROBE);
  assert.equal(jittered(1000, () => 0), 500);
  assert.equal(jittered(1000, () => 1), 1000);
});

const click = (overrides = {}) => ({
  button: 0, metaKey: false, ctrlKey: false, shiftKey: false, altKey: false, defaultPrevented: false,
  href: "/chats", target: "", download: false,
  origin: "https://app.example", current: "https://app.example/contacts?tab=1",
  ...overrides,
});

test("blocksClick: a plain click on a link to another of the app's pages", () => {
  assert.equal(blocksClick(click()), true);
  assert.equal(blocksClick(click({ href: "https://app.example/you" })), true);
  assert.equal(blocksClick(click({ target: "_self" })), true);
  assert.equal(blocksClick(click({ href: "/contacts?tab=2" })), true, "another query is another page");
  assert.equal(blocksClick(click({ href: "/chats#latest" })), true, "another page, with a hash");
});

test("blocksClick: everything else is the browser's", () => {
  assert.equal(blocksClick(click({ button: 1 })), false, "middle click");
  for (const key of ["metaKey", "ctrlKey", "shiftKey", "altKey"]) {
    assert.equal(blocksClick(click({ [key]: true })), false, key);
  }
  assert.equal(blocksClick(click({ defaultPrevented: true })), false);
  assert.equal(blocksClick(click({ target: "_blank" })), false);
  assert.equal(blocksClick(click({ download: true })), false);
  assert.equal(blocksClick(click({ href: "https://other.example/" })), false);
  assert.equal(blocksClick(click({ href: "#section" })), false, "within this page");
  assert.equal(blocksClick(click({ href: "/contacts?tab=1#section" })), false, "within this page, spelled out");
  assert.equal(blocksClick(click({ href: "http://[bad" })), false, "an href that isn't a URL");
});
