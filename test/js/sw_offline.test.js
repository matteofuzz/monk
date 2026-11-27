import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

// The pwa template's sw.js, run in a fake worker scope: page loads only,
// and only when they fail, get the app's offline page; everything else is
// the network's, untouched and never stored.
const source = readFileSync(new URL("../../lib/monk/templates/pwa/public/sw.js", import.meta.url), "utf8");
const ORIGIN = "https://shop.com";
const OFFLINE_HTML = "<p>offline</p>";

// `network(url)` answers each fetch: a Response, or throws (no network).
function worker(network) {
  const handlers = {};
  const fetched = [];
  const stores = new Map(); // cache name => Map(path => body)
  const self = {
    location: new URL(`${ORIGIN}/sw.js`),
    addEventListener: (name, handler) => { handlers[name] = handler; },
    clients: { claim: async () => {} },
    skipWaiting: () => {},
    registration: { navigationPreload: { enable: async () => {} } },
  };
  const caches = {
    open: async (name) => {
      if (!stores.has(name)) stores.set(name, new Map());
      const store = stores.get(name);
      return {
        put: async (key, response) => { store.set(key, await response.text()); },
        match: async (key) => (store.has(key) ? new Response(store.get(key)) : undefined),
        keys: async () => [],
        delete: async () => false,
      };
    },
  };
  const fetch = async (input, options = {}) => {
    const url = typeof input === "string" ? input : input.url;
    fetched.push([url, options.cache]);
    return network(url);
  };
  vm.runInNewContext(source, { self, caches, fetch, Response, URL, Set, Promise, Error, encodeURIComponent,
    decodeURIComponent });

  // Dispatches an event, waiting for respondWith's and waitUntil's promises.
  const dispatch = async (name, event) => {
    let response;
    const pending = [];
    handlers[name]({
      ...event,
      respondWith: (promise) => { response = promise; },
      waitUntil: (promise) => { pending.push(promise); },
    });
    const answer = await response;
    await Promise.all(pending);
    return answer;
  };
  return {
    fetched,
    stored: () => stores.get("monk-offline")?.get("/offline.html"),
    install: () => dispatch("install", {}),
    load: (path, { method = "GET", mode = "navigate", preload } = {}) =>
      dispatch("fetch", { request: { url: `${ORIGIN}${path}`, method, mode }, preloadResponse: preload }),
  };
}

const page = (body, status = 200) => new Response(body, { status, headers: { "content-type": "text/html" } });
const offlineServer = (pageStatus = 200) => (url) => (url === "/offline.html" ? page(OFFLINE_HTML) : page("app", pageStatus));
const noNetwork = () => { throw new TypeError("Failed to fetch"); };

test("install stores the offline page, fetched past the HTTP cache", async () => {
  const sw = worker(offlineServer());
  await sw.install();
  assert.equal(sw.stored(), OFFLINE_HTML);
  assert.deepEqual(sw.fetched, [["/offline.html", "reload"]]);
});

test("install offline still installs, and the next page load stores the page", async () => {
  let online = false;
  const sw = worker((url) => (online ? offlineServer()(url) : noNetwork()));
  await sw.install();
  assert.equal(sw.stored(), undefined);

  online = true;
  await sw.load("/chats");
  assert.equal(sw.stored(), OFFLINE_HTML);
});

test("a page load that works is the network's answer, untouched", async () => {
  const sw = worker(offlineServer());
  await sw.install();
  const response = await sw.load("/chats");
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "app");
});

test("no network: the offline page, as a 503 never cached", async () => {
  let online = true;
  const sw = worker((url) => (online ? offlineServer()(url) : noNetwork()));
  await sw.install();
  online = false;

  const response = await sw.load("/chats");
  assert.equal(response.status, 503);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(await response.text(), OFFLINE_HTML);
});

test("the proxy answering for an app that's down: the offline page", async () => {
  for (const status of [502, 503, 504]) {
    const sw = worker(offlineServer(status));
    await sw.install();
    assert.equal(await (await sw.load("/chats")).text(), OFFLINE_HTML, String(status));
  }
});

test("other errors are the app's own pages, shown as they are", async () => {
  for (const status of [404, 500]) {
    const sw = worker(offlineServer(status));
    await sw.install();
    const response = await sw.load("/chats");
    assert.equal(response.status, status);
    assert.equal(await response.text(), "app");
  }
});

test("no stored page yet: the proxy's answer, or the browser's error", async () => {
  const down = worker(() => page("bad gateway", 502));
  assert.equal(await (await down.load("/chats")).text(), "bad gateway");

  const offline = worker(noNetwork);
  assert.equal((await offline.load("/chats")).type, "error");
});

test("a navigation preload's answer is used instead of a second fetch", async () => {
  const sw = worker(offlineServer());
  await sw.install();
  sw.fetched.length = 0;
  const response = await sw.load("/chats", { preload: Promise.resolve(page("preloaded")) });
  assert.equal(await response.text(), "preloaded");
  assert.ok(!sw.fetched.some(([url]) => url.endsWith("/chats")));
});

test("anything but a GET page load is left alone: Live's resync, forms, assets", async () => {
  const sw = worker(noNetwork);
  assert.equal(await sw.load("/chats", { mode: "same-origin" }), undefined, "Live's resync is a fetch");
  assert.equal(await sw.load("/login", { method: "POST" }), undefined, "a form's POST");
  assert.equal(await sw.load("/js/app.js", { mode: "no-cors" }), undefined);
});

test("the offline page is refreshed once per start of the worker", async () => {
  const sw = worker(offlineServer());
  await sw.install();
  await sw.load("/a");
  await sw.load("/b");
  assert.equal(sw.fetched.filter(([url]) => url === "/offline.html").length, 2, "install, then one refresh");
});
