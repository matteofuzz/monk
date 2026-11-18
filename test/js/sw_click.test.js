import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

// The pwa template's sw.js, run in a fake worker scope: which window a
// notification's click goes to. Browser tabs and the installed app's
// windows look alike to the worker; app pages say which they are.
const source = readFileSync(new URL("../../lib/monk/templates/pwa/public/sw.js", import.meta.url), "utf8");
const ORIGIN = "https://shop.com";

function worker(windows) {
  const handlers = {};
  const log = [];
  const store = new Map();
  const client = (id, url) => ({
    id, url,
    focus: async () => { log.push(["focus", id]); return client(id, url); },
    navigate: async (to) => { log.push(["navigate", id, to]); return client(id, to); },
  });
  const self = {
    location: new URL(`${ORIGIN}/sw.js`),
    addEventListener: (name, handler) => { handlers[name] = handler; },
    clients: {
      matchAll: async () => windows.map(([id, url]) => client(id, `${ORIGIN}${url}`)),
      openWindow: async (url) => { log.push(["open", url]); },
      claim: async () => {},
    },
    skipWaiting: () => {},
    registration: {},
  };
  const caches = {
    open: async () => ({
      put: async (key, _response) => { store.set(new URL(key, ORIGIN).href, true); },
      keys: async () => [...store.keys()].map((url) => ({ url })),
      delete: async (request) => store.delete(request.url),
    }),
  };
  vm.runInNewContext(source, { self, caches, Response, URL, Set, encodeURIComponent, decodeURIComponent });

  const dispatch = async (name, event) => {
    let pending = Promise.resolve();
    handlers[name]({ ...event, waitUntil: (promise) => { pending = promise; } });
    await pending;
  };
  return {
    log,
    closeAll: () => { windows.length = 0; },
    open: (id, url) => windows.push([id, url]),
    store,
    message: (data, id) => dispatch("message", { data, source: { id } }),
    reportApp: (id) => dispatch("message", { data: { monkPwa: { standalone: true } }, source: { id } }),
    click: (url) => dispatch("notificationclick", { notification: { data: { url }, close: () => {} } }),
  };
}

test("no app installed: a tab already on the page comes forward", async () => {
  const sw = worker([["tab", "/"], ["tab2", "/chats/7"]]);
  await sw.click("/chats/7");
  assert.deepEqual(sw.log, [["focus", "tab2"]]);
});

test("no app installed: the open tab goes to the page", async () => {
  const sw = worker([["tab", "/"]]);
  await sw.click("/chats/7");
  assert.deepEqual(sw.log, [["focus", "tab"], ["navigate", "tab", `${ORIGIN}/chats/7`]]);
});

test("no window: a new one opens", async () => {
  const sw = worker([]);
  await sw.click("/chats/7");
  assert.deepEqual(sw.log, [["open", `${ORIGIN}/chats/7`]]);
});

test("the app's window, not a browser tab listed before it", async () => {
  const sw = worker([["tab", "/"], ["app", "/"]]);
  await sw.reportApp("app");
  await sw.click("/chats/7");
  assert.deepEqual(sw.log, [["focus", "app"], ["navigate", "app", `${ORIGIN}/chats/7`]]);
});

test("the app's window, even when a tab is on the page itself", async () => {
  const sw = worker([["tab", "/chats/7"], ["app", "/"]]);
  await sw.reportApp("app");
  await sw.click("/chats/7");
  assert.deepEqual(sw.log, [["focus", "app"], ["navigate", "app", `${ORIGIN}/chats/7`]]);
});

// Android and desktop Chrome open the app's own pages in the app.
test("the app installed but closed: a new window, not the tab left open", async () => {
  const sw = worker([["tab", "/"], ["app", "/"]]);
  await sw.reportApp("app");
  sw.closeAll();
  sw.open("tab", "/");
  await sw.click("/chats/7");
  assert.deepEqual(sw.log, [["open", `${ORIGIN}/chats/7`]]);
});

test("a closed app window is forgotten when another reports", async () => {
  const sw = worker([["app1", "/"]]);
  await sw.reportApp("app1");
  sw.closeAll();
  sw.open("app2", "/");
  await sw.reportApp("app2");
  assert.deepEqual([...sw.store.keys()].sort(), [
    `${ORIGIN}/_monk/pwa/app-window/app2`, `${ORIGIN}/_monk/pwa/installed`,
  ]);
});

test("an off-site url goes to the app's home", async () => {
  const sw = worker([]);
  await sw.click("https://evil.example/phish");
  assert.deepEqual(sw.log, [["open", `${ORIGIN}/`]]);
});

test("a tab's page, or any other message, marks nothing", async () => {
  const sw = worker([["tab", "/"]]);
  await sw.message({ monkPwa: { standalone: false } }, "tab");
  await sw.message("hello", "tab");
  assert.equal(sw.store.size, 0);
  await sw.click("/a");
  assert.deepEqual(sw.log, [["focus", "tab"], ["navigate", "tab", `${ORIGIN}/a`]]);
});
