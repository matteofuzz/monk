import { test } from "node:test";
import assert from "node:assert/strict";
import { platform, inApp, showInstall } from "../../lib/monk/pwa/client/platform.js";

const UA = {
  iphone: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1",
  ipad: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Safari/605.1.15",
  android: "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Mobile Safari/537.36",
  desktop: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36",
  instagram: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 380.0.0.0.0 (iPhone16,2; iOS 26_6; en_US)",
  facebook: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/500.0.0.0]",
  line: "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Mobile Safari/537.36 Line/14.0.0",
};

test("platform: iOS, iPadOS posing as a Mac, Android, anything else", () => {
  assert.equal(platform(UA.iphone, 5), "ios");
  assert.equal(platform(UA.ipad, 5), "ios");
  assert.equal(platform(UA.ipad, 0), "other", "a real Mac has no touch screen");
  assert.equal(platform(UA.android, 5), "android");
  assert.equal(platform(UA.desktop, 0), "other");
});

test("inApp: a social app's built-in browser, not the real one", () => {
  assert.ok(inApp(UA.instagram));
  assert.ok(inApp(UA.facebook));
  assert.ok(inApp(UA.line));
  assert.ok(!inApp(UA.iphone));
  assert.ok(!inApp(UA.android));
  assert.ok(!inApp("Mozilla/5.0 (X11; Linux x86_64) Gecko/20100101 Firefox/140.0 Online/1.0"), "no false Line/ match");
});

test("showInstall: iOS, or Android once Chrome offered its prompt, never in the app or on a desktop", () => {
  assert.equal(showInstall({ platform: "ios", standalone: false, installable: false }), true);
  assert.equal(showInstall({ platform: "ios", standalone: true, installable: false }), false);
  assert.equal(showInstall({ platform: "android", standalone: false, installable: false }), false);
  assert.equal(showInstall({ platform: "android", standalone: false, installable: true }), true);
  assert.equal(showInstall({ platform: "other", standalone: false, installable: false }), false);
  assert.equal(showInstall({ platform: "other", standalone: false, installable: true }), false);
  assert.equal(showInstall({ platform: "android", standalone: true, installable: true }), false);
});
