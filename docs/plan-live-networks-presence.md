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
| `pageshow` with `persisted` (restored from the back/forward cache) | The old socket is gone (browsers close it when the page enters the cache): connect now, which resyncs. |
| `resume` (Chrome's page lifecycle, after `freeze`) | Same as becoming visible. |

- "Connect now" still jitters, but from the first step (0–750 ms), not
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

## Part B: Presence

### B0. ADR 0019 first

The roadmap asks for an ADR before code. The questions, with what this
analysis would recommend:

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

- Migration in Monk's template (`00000000000005_create_presence_tables`):
  `monk_presence_processes (id, hostname, pid, heartbeat_at)` and
  `monk_presence (process_id, subject, sockets, visible_sockets,
  last_seen_at, PRIMARY KEY (process_id, subject))`, an index on
  `subject`, and `monk_presence_last_seen (subject PRIMARY KEY,
  last_seen_at)`, written by `monk add presence` (open question 5).
- The counts Ractor, fed by `Server.serve` (connect after the 101, leave
  in the ensure) without an ask: a send, so a connect never waits on it.
- Visible or hidden per socket, from Live's pings (open question 6):
  `Live::Session` notes the time of each `{"op":"ping"}` and tells the
  counts Ractor when a socket crosses the `2 × HEARTBEAT` line, either
  way. The server needs `HEARTBEAT` too: a Ruby constant mirroring
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
- `on_change` dispatch from the flusher/pruner, after the grace.

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
- `docs/design/websocket.md`: the pong tracking that "no pending-ping
  tracking exists" said was missing.
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
   presence, on a phone, outside this repo.

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
