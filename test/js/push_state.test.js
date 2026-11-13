import { test } from "node:test";
import assert from "node:assert/strict";
import { pushState, shouldResubscribe, keyBytes, sameKey, csrfToken, isIos } from "../../lib/monk/push/client/state.js";

const desktop = {
  secure: true, serviceWorker: true, pushManager: true, notification: true, ios: false, standalone: false,
  permission: "default", subscribed: false,
};

test("pushState: off until allowed and subscribed", () => {
  assert.equal(pushState(desktop), "off");
  assert.equal(pushState({ ...desktop, permission: "granted" }), "off");
  assert.equal(pushState({ ...desktop, permission: "granted", subscribed: true }), "subscribed");
  assert.equal(pushState({ ...desktop, permission: "denied" }), "denied");
});

test("pushState: unsupported without https, a service worker or the Push API", () => {
  for (const missing of ["secure", "serviceWorker", "pushManager", "notification"]) {
    assert.equal(pushState({ ...desktop, [missing]: false }), "unsupported", missing);
  }
});

// iOS has no PushManager in a Safari tab, only in a Home Screen app.
test("pushState: an iOS tab needs the app installed first", () => {
  assert.equal(pushState({ ...desktop, ios: true, pushManager: false }), "needs-install");
  assert.equal(pushState({ ...desktop, ios: true, standalone: true }), "off");
  assert.equal(pushState({ ...desktop, ios: true, standalone: true, pushManager: false }), "unsupported");
});

test("shouldResubscribe: only when allowed and not turned off here", () => {
  assert.equal(shouldResubscribe({ permission: "granted", optedOut: false }), true);
  assert.equal(shouldResubscribe({ permission: "granted", optedOut: true }), false);
  assert.equal(shouldResubscribe({ permission: "default", optedOut: false }), false);
  assert.equal(shouldResubscribe({ permission: "denied", optedOut: false }), false);
});

test("keyBytes decodes base64url without padding", () => {
  assert.deepEqual([...keyBytes("-_8")], [0xfb, 0xff]);
  assert.deepEqual([...keyBytes("AQID")], [1, 2, 3]);
  assert.equal(keyBytes("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4").length, 65);
});

test("sameKey compares an ArrayBuffer with bytes", () => {
  const key = keyBytes("AQID");
  assert.equal(sameKey(key.buffer, keyBytes("AQID")), true);
  assert.equal(sameKey(key.buffer, keyBytes("AQIE")), false);
  assert.equal(sameKey(null, key), false);
  assert.equal(sameKey(key.buffer, keyBytes("AQIDBA")), false);
});

test("csrfToken reads Monk::Auth's cookie", () => {
  assert.equal(csrfToken("a=1; csrf_token=ab%3Dc; b=2"), "ab=c");
  assert.equal(csrfToken("csrf_token=x=y"), "x=y");
  assert.equal(csrfToken("a=1"), null);
  assert.equal(csrfToken(""), null);
});

test("isIos knows iPadOS, which says Macintosh", () => {
  assert.equal(isIos("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", 5), true);
  assert.equal(isIos("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", 5), true);
  assert.equal(isIos("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", 0), false);
  assert.equal(isIos("Mozilla/5.0 (Linux; Android 14)", 5), false);
});
