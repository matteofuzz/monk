# 0.24: Live on real networks, and presence — plan

Drafted 2026-11-10, analysis only: nothing is built yet. Roadmap item 3
(`docs/roadmap.md`). Two parts that share one mechanism, knowing whether
a socket is still alive:

- **A. Live on real networks.** The Live client and the WebSocket server
  notice a dead socket on their own, and a page that comes back from the
  background reconnects and resyncs at once.
- **B. Presence.** Monk knows which subjects have a socket open, across
  processes, and an app can ask "is this person online?" and hear when
  that changes.

A comes first: presence that can't tell a dead socket from a live one
would show a phone that left an hour ago as online.

## What exists today

**Client** (`lib/monk/live/client/monk_live.js`, logic in `protocol.js`):

- Reconnects on `onclose` with a jittered backoff, 500 ms doubling to 30 s
  (`nextDelay`, `jittered`). The backoff only resets in `onopen`.
- After a reconnect it resubscribes, then refetches the page once the
  server acknowledged (`needsResync`, ADR 0011). A seq gap also resyncs.
- It only learns of a dead socket from `onclose`. Nothing times out: no
  heartbeat, no `visibilitychange`, `pageshow`, `online` or `freeze`/
  `resume` handlers. A pending backoff timer (up to 30 s) isn't cut short
  when the network comes back or the tab becomes visible.
- Browser JS can't send or see WebSocket ping frames, so any client-side
  liveness check needs a message of Live's own protocol.
- The protocol has `subscribe`/`unsubscribe` from the client and
  `subscribed`/`unsubscribed`/`error`/envelopes from the server
  (`Live::Session#dispatch`). An unknown op gets `error: bad_message`.

**Server** (`lib/monk/websocket/server.rb`, `connection.rb`):

- `ping_interval:` (off by default) sends a ping every N seconds
  (`Connection#start_heartbeat`). Pongs are discarded: "no pending-ping
  tracking exists" (`Connection#read`, opcode `0xA`). So the ping keeps a
  proxy's idle timeout away, but never tells the server the peer is gone.
- A peer that vanished without a FIN or RST (a phone that changed network,
  went into a tunnel, had its radio put to sleep) leaves the socket open.
  With nothing to send, Linux never notices; with a ping pending, it
  gives up after `tcp_retries2` retransmissions, about 15 minutes. Until
  then the connection Ractor, its registry entries and (later) its
  presence stay.
- Neither the scaffolded `bin/websocket_server`
  (`lib/monk/templates/websocket/bin/websocket_server`) nor monk_talk's
  sets `ping_interval:`, so behind a proxy with an idle timeout (nginx's
  `proxy_read_timeout`, 60 s by default) a quiet page is cut every
  minute and reconnects, refetching itself each time.

**Presence**: nothing in Monk. `docs/guides/live.md` ("Cost and limits")
lists it as not built. `Registry#count(key)` counts only its own
process's sockets (`docs/design/ws-horizontal-scaling-considerations.md`),
and with `WS_PROCESSES` > 1 or replicas that's a slice.

**What the first app needs** (monk_talk, `doc/candidate_plan.md` V0.3):

- A status per person: Online / Away / Reachable / Offline, "derived from
  'app connected' and 'notifications work', never chosen by hand", and a
  live online dot.
- Today it shows "online" as "has a valid session"
  (`app/models/active_users.rb`): logged in somewhere, not connected.
  It asks only about the people on screen, a list of subjects at a time.
- Its V0.3 lists a "tech investigation first" on exactly this release's
  questions: mobile browsers' sockets when backgrounded or suspended, and
  "a heartbeat or timeout rule for 'connected'".
- Reachable (push works) is 0.25's. Away needs to come from the client:
  only it knows the tab is hidden.

**Patterns to reuse:**

- `Monk::Jobs` already keeps a row per process with a heartbeat and prunes
  processes silent for `process_timeout` (`lib/monk/jobs/runtime.rb`,
  `heartbeat_interval: 15, process_timeout: 120`). Presence across
  processes is the same problem: rows owned by a process that may die
  without cleaning up.
- Monk-owned tables ship as numbered migrations in the module's template
  (`lib/monk/templates/auth/db/migrate/00000000000001_…`,
  `…/jobs/db/migrate/00000000000003_…`).
- `Registry` is a Ractor holding a Hash behind asks. A per-process
  presence table in memory has the same shape.
- The browser tests' `WsProxy` (`test/live_browser_helpers.rb`) already
  has `sever!` and `drop_next_server_frame!`. A `blackhole!` (stop
  forwarding in both directions, close nothing) reproduces a phone that
  changed network.

## Part A: Live on real networks

### A1. The server notices a dead peer

Done 2026-11-10 on `main_dev/live_networks`: `Connection` (the idle
deadline, `IDLE_PINGS`, a ping skipped rather than waited for),
`Server::MIN_PING_INTERVAL`, `ping_interval: 25` in the scaffold, tests in
`test/websocket_heartbeat_test.rb` (including a write blocked on a full
buffer, which fails with a ping sent through the write mutex), the
WebSocket, deploying and upgrading guides, and the changelog.

`Connection` records when it last read a frame (any frame: data, pong,
ping, close), with a monotonic clock. The heartbeat thread sleeps until
the earlier of its next ping and the idle deadline, and closes the
connection (`shutdown`, as `#close` does) once nothing has been read for
`ping_interval × 2` (decided, see open question 2). `Server.new` refuses
a `ping_interval:` under 5 s.
`Server.serve`'s ensure then runs as on any other close: unsubscribe,
and (B) presence.

- Cost: one `Process.clock_gettime` per frame read, one comparison per
  tick. No new thread.
- A browser answers pings without any JS, even in a backgrounded tab: the
  pong is the network stack's, not the page's. A frozen page (iOS
  suspending Safari) may or may not answer; to measure in A0.
- Default on in the scaffold: `ping_interval: 25`, under nginx's 60 s and
  Cloudflare's 100 s. In `Server.new` it stays off by default, as today.

### A2. The client notices a dead socket

Done 2026-11-12 with A3 on `main_dev/live_networks`: `{"op":"ping"}` in
`Live::Session#dispatch`; `HEARTBEAT`, `PONG_TIMEOUT`, `pingMessage`,
`reconnectDecision`, `returnAction` in `protocol.js` (Node tests);
the heartbeat, generation counter and lifecycle handlers in
`monk_live.js`; browser tests in
`test/live_client_network_browser_test.rb` (7 of 8 fail against the old
client; the eighth, an answering socket staying open, is the control); the Live
guide ("On phones"), the changelog. The pong timeout on coming back is
`PONG_TIMEOUT` too, not a shorter one: on iOS the close itself arrives
within milliseconds of unlock, so a shorter probe would gain nothing
measured.

A ping in Live's own protocol: `{"op":"ping"}` → `{"op":"pong"}`,
answered by `Live::Session#dispatch` without touching the registry.

- While the page is visible, the client sends one every `HEARTBEAT`
  (25 s, see Q3) and expects a pong, or any other frame, within
  `PONG_TIMEOUT` (10 s).
- On timeout the socket is treated as dead *now*: handlers detached, a
  best-effort `close()`, `disconnected` emitted with
  `{ reason: "timeout" }`, and a reconnect scheduled. Not waiting for
  `onclose`, which on a dead network can take a minute or more.
- A generation counter: every `connect()` makes a new one, and handlers
  of an older socket ignore their events. Today a late `onclose` from a
  socket the client gave up on would schedule a second reconnect.
- The ping also counts as activity for A1, so a Live page keeps the
  server's idle timer fresh even where the server's own ping is off.
- While hidden, no client pings: browsers throttle timers in hidden tabs
  (Chrome to once a minute after five minutes), so a timeout there would
  fire late and wrongly. The server's ping and A1 cover hidden pages.
  Presence relies on this rule: pings stopping is how the server knows a
  page is hidden (Away, open question 6).

### A3. Coming back: visibility, network, back/forward cache

| Event | What the client does |
|---|---|
| `visibilitychange` to visible | If no socket is open: cancel the backoff timer, reset the delay, connect now. If one is open: ping now with a short timeout (A2). Either way the existing resync-after-subscribe rule refetches the page if the socket was new. |
| `online` | Same as becoming visible. |
| `offline` | Cancel the pending reconnect; wait for `online` or visible. Saves a phone's battery from a 30 s loop that can't succeed. |
| Socket closed while the page is hidden | Decided (2026-11-12): reconnect once, then wait until it's visible again. Android keeps a hidden page's socket (A0, Android runs), so one attempt brings it back without unlocking; iOS resets a socket opened by a hidden page within ~2 s (A0, iOS run 4), so after that one attempt it stops. A hidden desktop tab whose server stayed down past that attempt catches up with one resync when shown. |
| `pageshow` with `persisted` (restored from the back/forward cache) | The old socket is gone (browsers close it when the page enters the cache): connect now, which resyncs. |
| `resume` (Chrome's page lifecycle, after `freeze`) | Same as becoming visible. |

- "Connect now" still jitters, but from the first step (250–750 ms), not
  from wherever the backoff had reached. Many pages becoming visible at
  once isn't a real pattern, unlike a server restart.
- A resync that failed is retried on the same events, not only on its
  own timer.
- New DOM events for apps and tests: `monk-live:stale` (a ping timed
  out), and `reason` on `disconnected`.

### A0. Measure first

Before A1–A3, a short spike, recorded in this plan:

1. **Headless Chrome, through `WsProxy#blackhole!`**: how long until
   `onclose` today (expected: much longer than a minute), and on the
   server, how long until the connection Ractor ends with and without
   `ping_interval:`.
2. **Lifecycle in Chrome via CDP**: `Page.setWebLifecycleState`
   (`frozen`/`active`), `Emulation.setFocusEmulationEnabled`, the back/
   forward cache (`Page.navigate` away and `history.back()`): which events
   fire, whether the socket survives, whether a frozen page answers the
   server's pings.
3. **Real devices, by hand** (iOS Safari, Android Chrome; a PWA on iOS
   can wait for 0.25): Wi-Fi to cellular with the page open; screen off
   for 1, 5 and 15 minutes; app switched away. What the page shows, what
   the server's log shows, how long until both agree. On a deployed app
   behind a real proxy (TLS, `wss://`), since that's what the roadmap
   item is about. This is also monk_talk's "tech investigation", done
   once for every Monk app.

The numbers set `HEARTBEAT`, `PONG_TIMEOUT` and the scaffold's
`ping_interval:`, and say whether a frozen tab counts as connected (B).

### A0 results: headless Chrome (2026-11-10)

Chrome 157 (`headless: :new`, Ferrum) on macOS, this checkout (0.23.1),
the browser tests' rig: page server, `WsProxy`, a `Server` running
`Live::HANDLER`. One run each; the script stayed out of the repo, and
`WsProxy#blackhole!` went into `test/live_browser_helpers.rb` for A1–A3's
tests.

1. **Silent network (`blackhole!`), watched 90 s.** Neither the client
   (`onclose`) nor the server (registry entry) noticed, with or without
   `ping_interval: 5`: the server's pings vanish, no pong comes back, and
   nothing reads that as dead. This is the worst case, both ends' own TCP
   healthy, but it's what A1 and A2 must catch on their own, and today
   nothing does.
2. **Frozen page** (`Page.setWebLifecycleState`, 20 s; Chrome makes the
   page hidden first). The pongs kept coming, 20 of 20 at one ping a
   second: they're the network stack's, not the page's. The server saw a
   healthy connection the whole time. On `resume` Chrome closed the
   socket at once (`disconnected` 1–3 ms after `resume`), whether or not
   anything was sent during the freeze, and the client reconnected and
   resynced through today's backoff (~500 ms later). So:
   - a frozen tab counts as connected to the server, and only Live's
     heartbeat rule (no Live ping while hidden) shows it as Away: B's
     choice holds up;
   - A1's idle timeout won't close a frozen Chrome tab (it answers pings);
   - A3's `resume` handler only saves the first backoff step.
3. **Visibility.** Bringing another tab to the front (`Page.bringToFront`)
   makes the page really `hidden` in headless Chrome, with
   `visibilitychange` both ways: tests needn't fake `visibilityState`.
4. **Offline emulation** (`Network.emulateNetworkConditions`, 15 s).
   `offline` and `online` fire, but the open WebSocket is left alone: not
   closed, still delivering. Good for testing A3's `offline`/`online`
   handlers, useless for simulating a dead socket (that's `blackhole!`).
5. **Back/forward cache.** With the test server's `Cache-Control:
   no-store` the page isn't cached (`MainResourceHasCacheControlNoStore`,
   `WebSocketUsedWithCCNS`). Monk sets no `Cache-Control` on HTML, so
   real pages are; without the header the page was restored: `pagehide`
   (persisted) → `freeze` → … → `resume` → `pageshow` (persisted), the
   socket's close delivered 3 ms after `pageshow`, and today's backoff
   reconnected and resynced ~500 ms later. A3's `pageshow` handler saves
   that step. The browser tests need a way to serve a page without
   `no-store`.

Not measured here: how long a Linux server takes to drop a peer that
really vanished (packets dropped, not a silent proxy). With a ping
pending it's `tcp_retries2`'s ~15 minutes by the kernel's documentation;
A1 makes it moot.

### A0 still open: real devices, by hand

On a deployed Live app behind TLS (`wss://`) and a real proxy, server
log at hand, with a page that shows `monk-live:*` events on screen.
For each of iOS Safari and Android Chrome:

1. Page open, Wi-Fi off (cellular takes over). Time until the page
   notices (`disconnected`), and until the server drops the socket.
2. Same, in airplane mode for 30 s then back.
3. Screen locked for 1, 5 and 15 minutes. On unlock: does the socket
   survive, is a `disconnected` delivered, how long until `resynced`?
   Server side: did pongs keep coming while locked, and when did the
   socket close?
4. Switched to another app for 1 and 5 minutes, then back: same
   questions.
5. A patch published while locked: applied on return, or brought back
   by the resync?

Item 3's server-side answer decides whether A1 alone can mark a locked
phone offline, or only the heartbeat rule marks it Away.

Decided 2026-11-13: what the LAN runs below didn't cover moves to the
first deploy of the real app with 0.24 (phase 7), behind TLS and its
proxy: iPhone with the A2 client (lock, app switch for 1 and 5 minutes),
airplane mode for 30 s, lock for 15 minutes, and why Android
DuckDuckGo's socket closed cleanly after 441 s. Part A is merged into
`main_dev/0_24_0` without them; B doesn't wait on them, since the LAN
runs answered what a locked phone does to its socket.

Run on the local network (the Mac's LAN IP, plain `ws://`, no proxy), with
a throwaway scaffolded Live app: a page logging `monk-live:*` and
lifecycle events, patches sent after a delay, and the WS server logging
each socket's open and close. This checkout, so with A1, `ping_interval:
25`.

**iOS Safari, item 3 (2026-11-10)**: screen locked twice, for 47 s and
3 min 35 s.

| | locked | server: socket reset | page on unlock |
|---|---|---|---|
| 1 | 16:48:41.9 | 16:48:58.4 (+16.5 s), `ECONNRESET` | JS paused ~47 s; `disconnected` at once, `connected` +0.5 s, `resynced` |
| 2 | 16:51:19.4 | 16:51:35.8 (+16.4 s), `ECONNRESET` | JS paused ~215 s; same |

Later runs, same page, same day:

| | hidden | server: socket reset | page on unlock |
|---|---|---|---|
| 3 | 16:57:04.2 | 16:57:21.8 (+17.5 s) | JS paused ~70 s; same as above |
| 4 | 16:58:14.2, 0.2 s after unlocking, before the reconnect had finished | 16:58:16.3: the new socket, opened at 16:58:14.5 while hidden, reset after 1.8 s | — |
| 5 | (run 4 continued) | | JS paused ~3124 s (52 min); no reload: same page, same JS heap; `disconnected`, `connected` +0.6 s, `resynced` |

- A socket opened while the page is already hidden is reset within ~2 s,
  not ~16.
- 52 minutes locked: iOS kept the page (no "page loaded" in the log) and
  only suspended it; recovery on unlock was the same as after a minute.

- **iOS doesn't keep the socket of a locked page.** About 16 s after the
  page goes hidden it resets it (an RST, not silence), and the server
  sees that at once: neither A1 nor the heartbeat is involved. The
  page's JS is suspended the whole time, and the close reaches it only
  on unlock.
- **For presence this means a locked iPhone is Offline, not Away**, after
  ~16 s plus the grace. Away, as decided (open question 6), lasts those
  16 s on iOS; it stays meaningful for a hidden desktop tab and for
  Android, which keeps a locked page's socket (below). "Phone in
  pocket, app open" can't be told apart from "closed the app" through a
  WebSocket on iOS: it's what "Reachable" (0.25's push) is for in the
  first app's status rule. Input for the ADR: whether the grace before Offline should cover this (a longer one
  only for sockets closed while hidden?), or Offline is the honest answer.
- **Recovery already works**: on unlock the client reconnects after the
  first backoff step (~0.5 s) and resyncs. A3's `visibilitychange`
  handler would save that step.
- **A patch sent while locked** (run 6): "patch in 90 s" asked at
  17:58:10.2, page hidden at 17:58:13.7, socket reset at 17:58:30.2
  (+16.5 s), patch sent at 17:59:40.4 to no socket. On unlock
  (18:03:03.2, JS paused ~289 s): `disconnected` +4 ms, `connected`
  +0.7 s, `resynced` +0.84 s. The patch is lost as a patch; the
  refetch brings the page to the server's current state under a second
  after unlock. (The test page renders the time of the request, not the
  last patch, so it shows the refetch rather than the patch's content.)
  On iOS, a patch to a locked phone never arrives as a patch: the
  resync is the only path, which is ADR 0011's design anyway.
- **Switching to another app** (run 7, 2026-11-11): socket opened at
  09:39:13.98, page hidden at 09:39:19.61, socket reset at 09:39:22.80
  (**+3.2 s**, against ~16 s for a lock). Back after ~58 s (JS paused):
  `disconnected` +11 ms, `connected` +0.45 s, `resynced` +0.49 s. So on
  iOS a hidden Safari page keeps its socket for ~16 s when locked, ~3 s
  when the user switches app, ~2 s when the socket was opened while
  hidden.
- **A3 should not connect while hidden**: a reconnect that fires while the
  page is hidden gets a socket iOS resets within ~2 s, and a resync for
  nothing. Wait for `visibilitychange` to visible instead.
- **Android keeps the socket of a locked page** (DuckDuckGo browser,
  Chromium-based, Android 10, 2026-11-12): socket opened at 10:13:56.2,
  page hidden at 10:14:24.3, timers throttled (JS paused 3–7 s at a
  time), `freeze` at 10:15:44.8 (+80 s), unlocked at 10:15:50.8
  (`resume`, `visible`). The socket stayed open the whole ~86 s and
  after, with no `disconnected`, no reconnect, no resync, and no close
  on the server: the browser kept answering server pings while frozen
  (as headless Chrome did in A0), so A1 never fired. Unlike headless
  Chrome, it didn't close the socket on resume. So on Android a locked
  page with its socket open is exactly the hidden-but-reachable case
  Away is for.
- **On Android a patch sent while locked arrives as a patch** (same
  browser and socket `q0`): "patch in 90 s" asked at 10:16:43.6, page
  hidden at 10:16:47.0, `freeze` at 10:18:07.0, patch sent at 10:18:12
  into the frozen page's open socket. Unlocked at 10:20:22.6 (JS paused
  ~136 s): `live:patched` (`#stamp`, morph, matched 1) **+183 ms** after
  `visible`, with no disconnect or resync. The browser buffered the
  frame while the page was frozen and delivered it on resume. The
  socket then closed cleanly (no reset) at 10:21:17 after 441 s, after the
  screenshot (tab closed or left, to confirm).
- **Wi-Fi off with the page on screen, iOS** (2026-11-12): socket `qg`
  opened at 10:25:08.7. With Wi-Fi off, the page got `disconnected` at
  10:25:34.0 on its own: iOS closes a socket when its interface goes
  away, so the client needs no heartbeat here (its reconnects then fail
  until Wi-Fi is back: the cellular network can't reach the LAN
  server). The server heard nothing (no FIN, no RST) and dropped `qg`
  at 10:25:51.8, 43 s after open and ~18 s after the phone lost it,
  with **`IO::TimeoutError: Blocking operation timed out!`** out of the
  handler, not through A1 (whose deadline was 10:25:59 at the earliest,
  50 s after the subscribe). Monk sets no `IO#timeout` (server.rb's `with_deadline`
  avoids it for a Ruby 4.0 bug), so where this came from is open: to
  find before A2 (the device app now logs the backtrace), and the
  handler should treat it as a disconnect, not an error. Wi-Fi back
  on: `connected` 10:26:49.3, `resynced` +51 ms.
  Repeat (10:31, Wi-Fi off for less than 25 s): socket `m8` opened at
  10:31:03.4. The page had already reconnected (`mg` at 10:31:28.24)
  when the server's next ping reached the phone, which answered it with
  an RST (`m8` reset at 10:31:28.5): iOS had already dropped the old
  socket. No `IO::TimeoutError`; a longer outage (60 s or more) is
  needed to reproduce it.
  Third run (10:53, Wi-Fi off 90 s, backtraces logged): socket `n4`
  opened at 10:53:22.9. The ping at +25 s raised `Errno::EHOSTDOWN` from
  `write_nonblock` (macOS, once the phone dropped off the LAN), which
  **ended the heartbeat thread**, and with it A1's close. The handler's
  `IO#read` then raised `IO::TimeoutError` at 10:54:05.9, again 43.1 s
  after open: macOS's TCP gave up on the unacknowledged ping after
  ~18 s, and Ruby 4.0 reports that kernel `ETIMEDOUT` as
  `IO::TimeoutError` (no `IO#timeout` is set). `Server.serve` swallows
  it like any handler error, so only the device app's log showed it.
  On Linux the kernel retransmits for ~15 minutes instead, and with the
  heartbeat dead A1 would never close the socket: the bug that matters.
  Fixed: `send_ping` skips a ping that fails with any
  `SystemCallError` and leaves the close to the deadline (test: a ping
  failing with `EHOSTDOWN` still closes a silent peer); the reverify
  thread's `close` rescues `SystemCallError` too.
- **Android Chrome, patch while locked** (Chrome, Android 10,
  2026-11-12; phone clock ~1.1 s ahead of the server's, times below are
  the server's): socket `n4` opened at 14:37:13.7, "patch in 90 s"
  asked, page hidden at ~14:37:38.6. The patch went out at 14:39:05.9
  and `live:patched` ran at ~14:39:19.0, **while still locked**: the
  page wasn't frozen yet, only throttled (JS paused 3–16 s at a time),
  so the frame waited for the next wake-up. `freeze` at ~14:40:06.2,
  +148 s after hidden (DuckDuckGo: +80 s). The socket stayed open
  through the freeze, as in DuckDuckGo. On unlock (~14:42:35.3) Chrome
  **closed it itself**, cleanly (server: `n4` closed at 14:42:35.4, no
  reset), as headless Chrome did on resume in A0 and DuckDuckGo didn't:
  `disconnected` +22 ms after `visible`, `connected` +0.56 s,
  `resynced` +0.78 s. A patch sent during the freeze probably dies with
  that socket (not tested); the resync covers it either way. For
  presence the locked phone stays reachable (Away), and the close on
  unlock is a sub-second reconnect the grace absorbs.
- **Android Chrome, locked for 7.5 minutes** (server times): socket
  `ns` opened at 14:45:00.1, page hidden at ~14:45:20.2, `freeze` at
  ~14:47:35.1 (+135 s). The phone **reset the socket at 14:50:19.1,
  299 s after hidden**, still locked, between two server pings (due
  14:50:00.1 and 14:50:25.1), so it was the phone's own decision, not an
  answer to a ping. One run: whether it's Chrome or Android, and whether
  it's always 5 minutes, isn't known. Unlock at ~14:52:50.4 (JS paused
  ~316 s): `disconnected` +53 ms (delivered only then), `connected`
  +0.81 s, `resynced` +0.90 s. So a locked Android phone in Chrome is
  Away for about 5 minutes, then Offline, as an iPhone is after 16 s.
- Not covered yet: app switch for 5 minutes on iOS (likely the same),
  Wi-Fi off on Android, Android lock for 5 minutes or more (does it ever drop the
  socket?), Android Chrome itself.

## Part B: Presence

### B0. ADR 0019 first

Written 2026-11-12, to review before any presence code:
`docs/adr/0019-presence-per-process-rows-in-postgres-settled-once-per-transition.md`.
It settles the questions below: rows per (process, subject) with
`status` and `gone_at`, counting while the process heartbeats and for
the grace once gone; readers derive the status; transitions settled by
any WS process into a logged `monk_presence_status`, which fires
`on_change` once and keeps `last_seen_at`. B1 below follows it. The
questions as they stood, with what this analysis recommended:

1. **WebSocket feature or Live feature?** Recommend: tracking in
   `Monk::WebSocket` (it's where sockets and subjects are, and an
   `app/sockets` handler gets it too), with Live adding the one thing
   only its client knows, whether the page is visible (Away, inferred
   from its heartbeat, open question 6). One module,
   `Monk::Presence` (or `Monk::WebSocket::Presence`), enabled by a
   `presence:` option on `Server.new`.
2. **Where the shared state lives.** Options:
   - *Each process's memory, shared through the fanout* (join/leave
     broadcasts): rejected. `bin/server` renders the online dot and has
     no sockets, so it has nothing to ask; a process that starts late
     never hears who joined before it.
   - *Redis* (hash per process with a TTL): only apps on the Redis
     transport have it, and presence needs subjects, so `Monk::Auth`, so
     Postgres anyway.
   - *Postgres*, decided (open question 4): presence needs `Monk::Auth`
     (item 8), which needs Postgres;
     readers are a plain query on the request path, like monk_talk's
     today. Presence without a database is left to the app.
3. **Writes.** A connect or close mustn't cost a query: a reconnect wave
   is 25K connects. Each WS process keeps its own counts in memory (a
   Ractor like `Registry`: subject → open sockets, visible sockets), and
   a flusher writes what changed once a second in one statement (arrays
   through `unnest`, upsert and delete). The table only ever holds a row
   per (process, subject), so its size follows who's online.
4. **A process that dies without disconnecting.** As `Monk::Jobs`: a
   `monk_presence_processes` row per WS process with a heartbeat. Readers
   ignore rows of a process silent for longer than a timeout; any WS
   process prunes them on its tick. A stopping process deletes its own
   rows. What timeout (Jobs uses 120 s; presence wants less, say 30 s
   with a 10 s heartbeat) is a measured choice.
5. **Flapping and restarts.** A phone switching network is offline for a
   few seconds; a WS deploy drops every socket at once. Without a grace
   period both read as "went offline" to everyone watching. Recommend a
   grace (say 20 s) before a subject counts as offline, applied where the
   transition is decided, not in each reader. Where that is, given that
   the process that saw the close may be the one stopping, is the hardest
   part of the ADR: either a `last_seen_at` kept on the row after its
   count reaches 0 and pruned after the grace, or the transition decided
   by a query any process runs.
6. **Hearing about changes.** An app wants "X came online" to patch the
   pages that show X. Recommend a boot-time hook in the WS process,
   `Monk::Presence.on_change { |subject, status| … }`, shareable like
   `authorize` rules, called once per global transition (after the
   grace), from which the app calls `Monk::Live.patch`. The alternative,
   apps polling, loses what makes it live.
7. **What a status is.** Decided: `:online` (a visible page open),
   `:away` (only hidden pages open), `:offline`, plus `last_seen_at`
   (open question 6). "Reachable" is the app's, from 0.25's push
   subscriptions. Whether a frozen tab still counts as a connection
   comes from A0. `last_seen_at` has to outlive the per-process rows
   (they go when the sockets do), so it's its own row per subject,
   written on each offline transition (the time of the last socket, or
   for a dead process its last heartbeat): one write per person going
   offline, not per connect. Whether that table is logged (it's shown to
   users, and an `UNLOGGED` one is emptied by a Postgres crash) is for
   the ADR.
8. **Only `Monk::Auth` subjects are tracked** (decided). Anonymous sockets
   (`authenticate: :optional`, or no auth) are not. Considered and
   rejected: an `identify:` hook on `Server.new`, a shareable proc
   turning the handshake's cookies into a subject, so an app without
   `Monk::Auth` (a label-only chat) could have presence too. It would
   add a second identity path at the handshake (Origin check, deadline,
   `db_pool:`, and rules for mixing it with auth) for a niche. If guests
   ever need presence, a cheaper route is a `Monk::Auth` call that opens
   a session for any subject (`"guest:…"`; the `sessions` table doesn't
   care, only `redeem` ties it to an email), so guests go through
   `authenticate:` unchanged.
   **Several tabs or devices**: one subject, counted once, online if any
   page is.

### B1. Building it, once the ADR is settled

- Migration in Monk's template (`00000000000005_create_presence_tables`),
  as ADR 0019: `monk_presence_processes (id, hostname, pid,
  heartbeat_at)` and `monk_presence (process_id, subject, status,
  gone_at, PRIMARY KEY (process_id, subject))`, both `UNLOGGED`, an
  index on `subject`, and the logged `monk_presence_status (subject
  PRIMARY KEY, status, changed_at, last_seen_at)`, written by
  `monk add presence` (open question 5). Socket counts stay in memory.
- The counts Ractor, fed by `Server.serve` (connect after the 101, leave
  in the ensure) without an ask: a send, so a connect never waits on it.
- Visible or hidden per socket, from Live's pings (open question 6):
  `Live::Session` notes the time of each `{"op":"ping"}` and tells the
  counts Ractor when a socket crosses the `2 × HEARTBEAT` line, either
  way. A Live socket starts hidden, and the client pings at once on
  open when its page is visible (a change to A2's client), so a visible
  page is Online within a frame. The server needs `HEARTBEAT` too: a Ruby constant mirroring
  `protocol.js`'s, with a test that reads the JS file and fails if they
  differ.
- The flusher and heartbeat thread in the WS process, through its own
  pool (`:presence`, size 1), started by `bin/websocket_server`. Its
  errors are logged and never end the process; on reconnect it rewrites
  its whole state (the counts are in memory, so nothing is lost).
- Readers, from any process: `Monk::Presence.status(subjects)` →
  `{subject => {status: :online | :away | :offline, last_seen_at:}}`,
  and `online?(subject)`. One query, the people on screen at a time, as
  monk_talk does today. The exact shape is for the ADR.
- Settling and pruning on each tick, in one transaction: the flushed
  subjects and those with expired rows, upserted into
  `monk_presence_status` only where the status differs; a full
  reconcile of non-offline subjects every minute.
- `on_change` from the settling process, after its commit, at most
  once per transition.
- A `TERM`ed process sets `gone_at` on all its rows instead of deleting
  them, so a deploy changes nobody's status.

## Tests

- `test/js/protocol.test.js`: the heartbeat/timeout decisions and the
  event table of A3 as pure functions (what to do given state + event),
  so the glue in `monk_live.js` stays thin.
- Browser tests (Ferrum): `WsProxy#blackhole!` → the client reconnects
  and resyncs within `PONG_TIMEOUT` + a jittered step; visibility and
  lifecycle through CDP; `online`/`offline` through
  `Network.emulateNetworkConditions`; a late event from an abandoned
  socket doesn't cause a second connect.
- Server: a blackholed client is closed after `2 × ping_interval`, and its
  registry entries are gone; a pong keeps it open.
- Presence, against real Postgres: two WS processes, a subject on both,
  one killed with `KILL` (no cleanup) → still online through the other;
  both killed → offline once the timeout passes; a reconnect inside the
  grace fires no `on_change`; a page hidden past `2 × HEARTBEAT` turns
  its subject `:away`, and back to `:online` on its probe when shown
  (headless Chrome, visibility through CDP); `last_seen_at` set on going
  offline, including through a killed process; a 25K connect wave is a few statements a
  second, not 25K (measured with `bin/benchmark_ws_connect`'s `live`
  variant, which must not get slower).
- 0 skips, as always: Postgres, Redis and floci up before the run.

## Docs and scaffold

- Scaffolded `bin/websocket_server`: `ping_interval: 25`, and presence
  when `config/presence.rb` exists. The `monk add presence` generator
  and its generator test (open question 5).
- `docs/guides/live.md`: a "Mobile and flaky networks" section (what the
  client does, the events, what an app still owns), and presence moved
  out of "Not built"; `docs/guides/websocket.md`: the idle timeout and
  presence; `docs/guides/deploying.md`: proxy idle timeouts vs.
  `ping_interval:`.
- `docs/guides/upgrading.md`, 0.24 section: the `bin/websocket_server`
  lines and the presence migration (old apps are internal, no compat
  shims).
- The pong tracking that "no pending-ping tracking exists" said was
  missing: that line was in `Connection#read`'s comment, now updated
  (A1).
- Roadmap item 3 marked done, without naming monk_talk.

## Phases

1. **A0**: the spike, numbers into this plan.
2. **A1**: server idle timeout; scaffold `ping_interval:`.
3. **A2 + A3**: Live ping/pong, client heartbeat, lifecycle events, tests.
   Shippable alone: everything in Part A helps every Live app.
4. **ADR 0019** (presence), reviewed before any presence code.
5. **B1**: tables, counts Ractor, flusher, pruning, readers, `on_change`,
   Away from Live's heartbeat, `last_seen_at`.
6. **Scaffold, guides, upgrade guide.**
7. **Check against the real app**: monk_talk's `ActiveUsers` replaced by
   presence, on a phone, outside this repo. On its first deploy with
   0.24, also the device checks left from A0 ("A0 still open").

Part A could go out as 0.24.0 and presence as 0.24.x if the ADR takes
longer; the roadmap pairs them because presence is what makes the mobile
work visible.

## Open questions

1. **Branches**: decided. `main_dev/0_24_0` integrates the release;
   Part A on `main_dev/live_networks`, presence (ADR 0019 included) on
   `main_dev/live_presence`, each merged into it by PR.
2. **Server idle timeout**: decided, tied to `ping_interval:`. A
   connection is closed once nothing has been read from it for
   `2 × ping_interval`: any frame counts (pong, data, close, and Live's
   own ping). No `ping_interval:`, no timeout: only a ping makes silence
   mean "dead", and without one a quiet but healthy client (a hidden tab,
   an `app/sockets` client that never sends) would be closed. What
   follows from it:
   - **Detection time follows the ping rate.** At 25 s a vanished peer is
     closed after 50 s, as long as the check runs on its own deadline
     (sleep until the earlier of the next ping and `last_read + 2i`)
     rather than on the ping tick, which would make it 50–75 s. With
     presence's grace and flush, offline shows within about 70 s.
     Faster means more pings, which wake a phone's radio.
   - **A minimum interval** (`ping_interval >= 5`, checked in
     `Server.new`). Reads stall during GC pauses (p99 4.2 s at 15K
     sockets, `plan-ws-connect-ceiling.md`) and slow `db_pool:` rules; a
     timeout near that would close healthy sockets in bulk and start a
     reconnect wave, which makes GC worse.
   - **Pings now imply the timeout.** An app that sets `ping_interval:`
     gets it too; a client that never answers pings (against RFC 6455)
     is dropped. One line in the 0.24 upgrade guide.
   - **A frozen tab that doesn't answer** (iOS, to confirm in A0) is
     closed and resyncs when it comes back: right for presence.
   - **Not locked in.** If presence needs faster offline detection than
     the ping rate allows, `idle_timeout:` defaulting to
     `2 × ping_interval` can be added later without breaking anything.
   - The scaffold sets `ping_interval: 25`.
3. **Client heartbeat interval**: decided, constants in `protocol.js`
   (`HEARTBEAT`, `PONG_TIMEOUT`, next to `INITIAL_DELAY`/`MAX_DELAY`),
   the same for every app. Starting at 25 s / 10 s, set from A0's
   numbers. The heartbeat only covers a visible page whose network died
   unnoticed (worst case `HEARTBEAT + PONG_TIMEOUT` before reconnecting);
   coming back from hidden or offline is A3's immediate probe, and hidden
   pages and proxy idle timeouts are the server's ping (question 2), so
   nothing on the server side has to match it. Not configurable: one
   less option to validate and get wrong (too low adds load across every
   visible page). If an app ever needs it, a `<meta
   name="monk-live-heartbeat">` written by `monk_head`, defaulting to the
   constant, can be added without breaking anything.
4. **Presence in Postgres only**: decided, even for apps on the Redis
   transport. An app that needs presence with no database at all (a
   label-only chat on Redis, say) is rare enough to be the app's own
   work. Why Postgres: `bin/server` renders the status and holds no
   sockets, so the state must be shared; one implementation of the
   grace/offline logic instead of two (Postgres heartbeats and Redis
   TTLs behave differently); readers can join presence with app tables
   ("which of my contacts are online") in one query; it ships as a
   numbered migration like auth and jobs, and works behind PgBouncer in
   transaction mode (plain statements, unlike `LISTEN`).
   - **An `UNLOGGED` table**, to confirm by measurement in B1: the rows
     are updated and deleted all the time, and unlogged skips the WAL.
     After a Postgres crash it comes back empty, which is fine since each
     WS process holds its counts in memory and rewrites them all after
     reconnecting. Unlogged tables don't reach read replicas: presence is
     read from the primary (Monk doesn't route reads to replicas today;
     the guide says so).
   - **The reader API stays store-agnostic** (`Monk::Presence.status(subjects)`),
     with no adapter layer built up front. A Redis store could be added
     behind it later without breaking anything.
5. **Scaffold**: decided, its own generator, `monk add presence`, with
   `depends_on :auth, :websocket` (as `live` depends on `:websocket`,
   ADR 0017). It writes the migration, `config/presence.rb` (the
   `:presence` pool and an empty `on_change` example), and its sections
   of `agents.md`/`setup.md`. `bin/websocket_server` loads
   `config/presence.rb` only if it exists, as it does `config/auth.rb`
   and `config/live.rb`, so the template stays one file. Not on by
   default when auth and websocket are both installed: `monk add` does
   nothing for an installed module, so presence would depend on the
   order the modules were added in, and every such app would pay a
   flusher thread, a pool connection and a table it may never read. An
   existing app turns it on with one command, which is all the upgrade
   guide has to say.
6. **Away**: decided, in Monk, inferred from Live's heartbeat (A2): no
   other channel, and no new message type. The page pings only while
   visible, and A3 probes the moment it becomes visible again, so a Live
   socket that answers the server's pings but has sent no Live ping for
   `2 × HEARTBEAT` belongs to a hidden page. Away is noticed after ~50 s
   (plus the grace); Online again is immediate. The ADR writes this rule
   down, so a later change to when the client pings can't silently
   change what Away means.
   - Rejected: an explicit `{"op":"visibility"}` message (instant, but the
     first client → server message in Live that isn't about
     subscriptions); closing the socket after a while hidden and deriving
     Away from recency (no live updates for background tabs, a refetch on
     every return); leaving Away to apps (only through a second channel,
     an HTTP post or another socket, which races the Live one).
   - Sockets that never send a Live ping (`app/sockets` clients) count as
     connected, with no Away.
   - Visible isn't "at the keyboard": an unattended desktop tab reads as
     Online. Idle detection is out of scope.
   - **`last_seen_at` too**, per subject: when it last had a socket open
     ("seen 5 min ago"), returned by the readers beside the status.
