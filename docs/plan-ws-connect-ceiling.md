# The WebSocket server's connect ceiling — plan

Drafted 2026-10-19, rewritten the same day after review. Items 1–5
done 2026-10-20 (see "After items 1–5"); the VM run and the rest are
open. Found by the
monk-vs-rails benchmark (its PLAN.md, "Phase 7 results"), which waits
for this before tuning: a fix released before its phase 7 tuning goes
in, one released later doesn't.

## The problem

On the benchmark's app VM (8 dedicated cores, monkrb 0.21.1, Ruby 4.0.7,
`bin/websocket_server` with auth and Live as the scaffold sets them up),
S6 opens 25K signed-in sockets, each subscribing to up to 15 topics:

- **At 500 connects/s it collapses.** 1,725 subscribed, 23,275 failed,
  connect p99 21.5 s, and every success came in the first 9.4 s. The
  `:auth` pool filled (`PoolFullError`, 1,000 calls waiting) and timed
  out while Postgres sat at 1.2% CPU. The WS process never used more
  than ~2.5 of its 8 cores.
- **At 100 connects/s it holds all 25K**, at 55 KB a socket, but each
  connect costs ~7 ms of CPU.
- Action Cable (2 queries a connect) and AnyCable both pass 500/s.

It matters beyond the benchmark: a WS restart drops every socket, and
`monk_live.js` brings them all back within 0.25–0.75 s (~50K/s for
25K pages), then backs off to 30 s; even at the cap, 25K pages arrive
at ~830/s. Each page that gets back in also refetches itself
(`resync()`), which is Kino's load, not the WS server's.

The earlier figure, "sockets settle at about 1,350 a second"
(`history/plan-pg-pool.md`, phase 11; `guides/persistence.md`), came
from 64 closed-loop clients opening at most 2,000 sockets, which never
overloads the server or holds many sockets. Both matter, as below.

## What was measured

`bin/benchmark_ws_connect` (new): an open-model client (each connect is
due at its time, and its latency counts from then) against a server in
a child process. The variants add up to what `bin/websocket_server`
does: `bare` (no auth), `auth` (`authenticate: :optional` through a
`db_pool:`), `live` (plus `Monk::Live`, ALLOW_ALL, 8 topics). Run in
Docker on a Mac (aarch64 Linux, the bench's Ruby 4.0.7 image), server
pinned to 4 cores, client to the other 4, this checkout (0.22.0, whose
WebSocket and Live code is 0.21.1's). One run each: the shape is
reliable, not the exact rates.

**1. GC pauses grow with the number of open sockets.** Live, 200
connects/s for 15 s, after first opening and holding N sockets:

| held | ready p99 | GCs | GC time | per GC |
|---|---|---|---|---|
| 0 | 22 ms | 133 | 1.3 s | 10 ms |
| 5,000 | 232 ms | 61 | 3.8 s | 62 ms |
| 15,000 | p50 2.8 s, p99 4.2 s | 67 | 13.2 s | 198 ms |

Marking is over 90% of GC time. Each GC costs ~12 µs per connection
Ractor, and stops every Ractor. Smaller thread stacks
(`RUBY_THREAD_VM_STACK_SIZE`, `_MACHINE_STACK_SIZE`) change nothing, so
it isn't whole-stack scanning. The cost is per socket. Whether it is per
Ractor or per thread (a Live socket has two, four with `ping_interval:`
and `reverify_interval:`) isn't separated yet. Minor and major GCs
weren't counted apart either.

**2. Connects decide how often GC runs.** Every GC was `newobj`
triggered: the heap ran out of free slots. A connect allocates 693
objects bare, 781 with auth and 928 with Live. Most of the gap is the
handshake's `IO#read(1)`, one String a byte of the request, about 300
of them. The heap stays small because little of it stays live, so with
sockets held a GC runs every ~45 connects (~22 with none held).

**3. With no back-pressure, overload ends in collapse, not a plateau.**
Every accepted socket gets a Ractor at once, whatever is already
waiting. Past the ceiling, the queue and the pool fill, calls time out,
and the work done goes to handshakes that fail anyway. The pool is a
victim, not the cause: one worker clears ~3,200 calls/s, but GC stops
its worker and dispatcher Ractors too. A pool failure in the handshake
(`identify`/`authenticate!` call `verify` outside `serve`'s rescue)
kills the Ractor with a backtrace on stderr (139K lines in the
benchmark's log), and the client gets no HTTP response.

**4. GC tuning buys a constant factor.** (Not so: with items 1–5 in,
it's the main lever; see "After items 1–5".) Live, 5,000 held:

| | 200/s p99 | 400/s | GC time at 400/s |
|---|---|---|---|
| defaults | 77 ms | 4,888/6,000 ready, p50 8.2 s | 18.4 s |
| `RUBY_GC_HEAP_FREE_SLOTS_MIN_RATIO=0.6`, `_GOAL_RATIO=0.8`, `_MAX_RATIO=0.9` | 183 ms | 6,000/6,000, p99 1.5 s | 7.7 s |

Not measured yet: how it scales from 4 cores to 8 on Linux on x86, and
the auth pool's share once GC is out of the way (`bare` and `auth` look
the same at up to 200/s).

## The model

The measurements fit one formula. GC time per connect ≈ (cost per
socket per GC × held) / (connects per GC) ≈ 12 µs × held / 45 ≈
0.27 µs × held. At 25K held that is ~6.7 ms, matching the VM's ~7 ms of
CPU per connect, measured separately. Since GC stops everything, the
ceiling is about

    ceiling ≈ k / held,   k ≈ 3.7M today

That is ~740/s at 5K held, ~250/s at 15K and ~150/s at 25K, which
agrees with all three measurements above. A restart's reconnect wave
starts from an empty server that slows as it fills (dn/dt = k/n), so
refilling n sockets takes at least

    t ≈ n² / 2k

which is ~85 s for 25K today, with back-pressure. Without it, the wave
collapses.

Two ways to move it. **Raising k** (fewer allocations, so fewer GCs,
and less to mark per socket) helps every app, by a constant factor.
**Dividing held** across K processes, each with its own heap and its
own pauses, divides both held and rate per process by K. That cuts GC
load by K², but only big apps need it. Success is stated in these
terms: k before and after, and t for 25K.

## After items 1–5

Measured 2026-10-20, same setup, Live unless named, one run each.
`bin/benchmark_ws_connect` now also prints, per heap, objects a connect,
slots and live slots.

**Objects a connect fell ~3×, k ~1.5×.** Bare 701 → 95, auth 781 → 173,
Live 931 → ~280.

| | before | after |
|---|---|---|
| 0 held, 400/s | 4,643/6,000 ready, p99 5.9 s, 431 GCs | 6,000/6,000, p99 55 ms, 129 GCs |
| 5K held, 400/s | p99 160 ms, 67 GCs | p99 123 ms, 96 GCs |
| 5K held, 600/s | 723/9,000 ready (collapse) | 9,000/9,000, p99 3.6 s, 229 GCs |
| 15K held, 200/s | p99 2.2 s, 83 GCs | p99 185 ms, 43 GCs |
| 15K held, 300/s | not run | 4,500/4,500, p99 6.3 s, 154 GCs |

k went from under 3M to about 3–4.5M. Without overload (5K held,
200–400/s) the GC count didn't fall, and at 400/s it rose.

**Why: GCs follow new Ractors, not objects.** On 4.0 each new Ractor
takes a page (64 KB, 1,638 slots) of the shared 40-byte heap for its own
allocations, however few it makes; the next GC sweeps what it didn't
use back. Ruby sizes the heap by what's live, so a GC comes every
(free 40-byte pages) new Ractors. Cutting garbage shrinks the heap and
leaves fewer free pages, which is why item 4 barely moved the count. A
microbenchmark, 5,000 Ractors each keeping N objects and blocking:

| N | GCs | with `RUBY_GC_HEAP_0_INIT_SLOTS=2000000` |
|---|---|---|
| 0 | 168–170 | 5 |
| 20 | 139–140 | |
| 200 | 52–53 | |

Pre-sizing the other heaps (80–640 B) changes nothing. With 2M slots
(~1,220 pages) a GC came about every 1,000 Ractors: about a page each.

**So heap size is the lever** (item 7). Live, after items 1–5, p99 to
ready:

| | defaults | `RUBY_GC_HEAP_0_INIT_SLOTS=2000000` | free-slot ratios 0.6 / 0.8 / 0.9 |
|---|---|---|---|
| 5K held, 600/s | p99 3.6 s, 229 GCs | p99 121 ms, 33 GCs | not run |
| 5K held, 800/s | p99 10.5 s | p99 1.8 s | not run |
| 15K held, 200/s | p99 185 ms, 43 GCs | p99 479 ms, 47 GCs | p99 390 ms, 7 GCs |
| 15K held, 300/s | p99 6.3 s, 154 GCs | p99 1.1 s, 27 GCs | p99 1.2 s, 5 GCs |
| RSS at 15K held, 300/s | 979 MB | 1,084 MB | 1,256 MB |

- A fixed pre-size is swamped once live objects pass it: at 15K held,
  ~1M live 40-byte slots against 2M. The ratios grow with what's held.
- With the ratios, the limit is the pause, not the count: 5 GCs in the
  300/s step, marking ~650 ms each. Every GC, minor ones included,
  marks every socket's Ractor and threads.
- At 15K held, steps above 300/s mean little: the client's own lag p99
  reaches 0.5–3 s at 400/s on its 4 cores.
- With either setting, about 700–800/s at 5K held and 300–350/s at 15K:
  k ≈ 4–5M.

## Ruby 4.1: per-Ractor GC

4.1.0-preview1 (12 Oct 2026) makes the default GC per Ractor: each
Ractor collects its own heap without stopping the others. A global,
stop-the-world GC still runs for a full `GC.start`, shareable-object
growth, and reclaiming exited Ractors' heaps. Unscoped `GC.stat` and
`GC.count` now cover only the calling Ractor; `bin/benchmark_ws_connect`
reads `GC.stat(scope: :global)` when it exists, and reports global GCs.

Measured 2026-10-19, same Docker setup, `bench-monk-41` image (the
official `ruby:4.1.0-preview1-slim-trixie` plus pg, rack, base64):

| | 4.0.7 | 4.1.0-preview1 |
|---|---|---|
| main Ractor allocating with 4,000 idle Ractors: GC time | 5,827 ms (825 GCs) | 111 ms (83 GCs) |
| the same with 4,000 threads in one Ractor | 2,255 ms | 1,105 ms |
| RSS per idle Ractor | 17 KB | 101 KB |
| full `GC.start`, 4,000 idle Ractors | 10–21 ms | 43–141 ms |
| RSS per Live socket (the server) | ~55–80 KB | ~590 KB |
| 1,000 exited Ractors, no `GC.start` | reclaimed | +~140 MB each round, never reclaimed |

- **The 4.0 problem goes away.** The model's held × rate term comes from
  every GC marking every Ractor. On 4.1 a connect's GCs stay in its own
  Ractor. On 4.0 the cost was per thread, not per Ractor: 4,000 threads
  in one Ractor cost about the same per GC as 4,000 Ractors, and still
  do on 4.1. So a Ractor per socket is the right shape for 4.1, and
  Fibers in N Ractors (item 9) the wrong one.
- **Preview1 can't run the server under churn.** Exited Ractors' heaps
  are reclaimed only by a global GC, which almost never runs on its
  own: the server was OOM-killed (8 GB) seconds after its first 3,000
  sockets closed. One global GC with 2,000–5,000 Ractors paused for
  0.8–3.9 s, mostly sweeping. Held 5K: 3 GB, p99 4.2 s from one such
  GC. 25K Live sockets would need ~15 GB.
- **Seen once:** `Digest::Base cannot be directly inherited` from
  `Digest::SHA1.digest` in a handshake, under load. Not reproduced
  outside Monk.

Reported upstream:
[#22454](https://bugs.ruby-lang.org/issues/22454) (exited Ractors'
heaps reclaimed only by a global GC) and
[#22455](https://bugs.ruby-lang.org/issues/22455) (~100 KB per idle
Ractor, and the global GC's cost). Both open, no replies yet. The
reproductions are in the reports.

**The page per Ractor, on 4.1** (2026-10-20, `bench-monk-41`,
microbenchmarks only):

- **#22455's ~100 KB is whole pages.** A 4.1 Ractor gets its own 64 KB
  page in each heap it uses, at least three (32, 40 and 64 B) even if
  it allocates nothing, and a fourth (256 B) for a kept 20-element
  Array. RSS per idle Ractor: 101 KB with N=0, 238 KB with N=20,
  173 KB with N=200 (4.0: 16–28 KB). The same design shows as GC count
  on 4.0 and as memory on 4.1.
- **#22454 is a missing trigger, not a leak.** Rounds of 2,000 Ractors
  that start, keep 20 objects and exit:

  | RSS above start | 4.0.7 | 4.1, no `GC.start` | 4.1, `GC.start` each round |
  |---|---|---|---|
  | round 0 | +37 MB | +465 MB | +465 MB |
  | round 1 | +41 MB | +859 MB | +858 MB |
  | round 5 | +56 MB | +2,429 MB | +859 MB |
  | global GCs | 32–80 a round | 1 in 6 rounds | 1 a round, 24 ms |

  On 4.0, new Ractors taking pages is what triggers GC, so exited
  Ractors' memory is reused without asking. On 4.1 nothing starts the
  global GC; one does reclaim it for reuse (RSS isn't given back to
  the OS).
- **Each exiting Ractor runs its own major GC** on 4.1: 5,000 exits,
  5,000 major GCs, no global one.
- **Item 7's settings don't reach a Ractor's own heap.** With
  `RUBY_GC_HEAP_0_INIT_SLOTS=2000000` and the min ratio set, a new
  Ractor still starts with one page per heap.

The likely fix for #22454, a global GC once exited Ractors hold enough
memory, brings back 4.0's coupling of GC to connect rate, with a
costlier GC: churn at 300/s × ~200 KB is ~60 MB/s, and a global GC
with 2,000–5,000 Ractors alive paused 0.8–3.9 s above. So a fixed 4.1
needs item 10's churn step with sockets held, measuring global-GC
pauses, not only that memory levels off. Neither finding is posted to
the reports yet.

What this means for the plan: items 1–5 are right on any Ruby. Items 6,
7 and 9 are 4.0 work that 4.1 may make unnecessary, so they wait for
what #22454 and #22455 become before 4.1's release. Item 8 (several
processes) stays the scale-out step either way, and on 4.1 is also the
way to limit how much memory one process's global GCs have to sweep.

## The plan, by size of app

The goal is one process that goes as far as Monk's code can take it,
with nothing added for a small app to configure, and a documented
scale-out step for a huge one.

### Small apps (up to ~5K sockets): fail cleanly, no settings

The ceiling here is already ~740/s. What's missing is a plateau instead
of a collapse. All of this is on by default.

1. **A cap on handshakes in flight.** The accept loop counts the
   connection Ractors still in their handshake. Each Ractor signals a
   `Ractor::Port` the server holds once it has written its response, or
   failed to. At the cap, the loop waits for a signal before it accepts
   again, and new connects wait in the kernel's backlog (`SOMAXCONN`).
   The cap covers the HTTP handshake and auth, not Live's subscribe.
   Subscribe goes to the registry, which item 5 cuts to one ask.
   Decision: the default (to be measured, tied to the pool's size and
   timeout so a full cap can't overfill its queue), and whether it's a
   `Server.new` option.
2. **A handshake deadline and a size limit.** Without them, item 1
   becomes a denial of service: a few hundred sockets that send nothing
   fill the cap. Today such a socket holds a Ractor forever, and a
   request with no `\r\n\r\n` grows without limit. `IO#timeout=` on the
   socket for the handshake (reset to nil before the handler runs, so
   an idle socket isn't timed out later), and the `limit` of item 4's
   `gets`.

   Done with a watchdog thread in the connection's Ractor instead, which
   shuts the socket down at the deadline (ending a blocked read) and is
   killed once the 101 is written; the deadline covers the whole
   handshake, the session check included. Not `IO#timeout=`: on 4.0.6
   and 4.0.7, once an `IO#timeout` has fired in one Ractor, a read in a
   Ractor made after it can raise `IO::TimeoutError` at once, on a
   socket with no timeout set (about 1 in 10 in a loop of a timed-out
   read in one Ractor, then a plain read in the next; never with
   threads in one Ractor). Not yet reported upstream.
3. **A refusal, not a crash.** A handshake whose `verify` raises (pool
   full, timed out, database down) answers `503` and logs one line, not
   a backtrace. `Retry-After` is added for non-browser clients only.
   Browser JS never sees a failed handshake's status or headers, just
   `onclose` with 1006, so `monk_live.js`'s jittered backoff remains the
   only back-off a browser gets. Under `:optional`, a failed verify is
   not treated as anonymous: that would quietly sign a user out of their
   topics.

### Medium apps (5K–25K): raise k

Everything here is code, and applies to every app.

4. **The handshake in one read.** `socket.gets("\r\n\r\n", limit)`
   instead of `read(1)` in a loop: one String, and it reads through the
   IO's own buffer, which `Connection#read_exactly` uses after it, so
   no bytes past the head are lost. A `readpartial` loop could read the
   client's first frame into the handshake buffer and drop it. Parse the
   request once: `Handshake.response_for` parses it again today, and
   `credential_from` splits the cookie up to three times.
5. **A subscribe in one registry ask.** `Registry#register_many(keys,
   port)` instead of one synchronous ask per topic, each of which
   allocates a reply `Port` and a message. At 500/s × 15 topics that is
   7,500 asks a second through one Ractor, cut to 500. Unsubscribe and
   cleanup likewise. Also: one reply port per caller thread, reused,
   instead of one per ask (an ask is synchronous, so a thread has at
   most one outstanding).
6. **Less kept alive per socket.** 55 KB a socket, and every live
   object is marked on every major GC. It won't lower the GC count
   (less live means a smaller heap, so it may raise it): its value is
   shorter marking, and it's measured on that. Measure what a held
   socket retains (`ObjectSpace.count_objects` per variant at N held,
   and how many end up old), then trim. Measured with item 5 as minor vs major
   GCs and marking time per GC.
7. **GC settings for the WS process.** In the scaffold's
   `bin/websocket_server` environment (Procfile, Dockerfile) and the
   deploying guide, so a user who runs it as documented gets them.
   After items 1–5 this is the main lever, not a constant factor: GCs
   follow new Ractors per free 40-byte page ("After items 1–5"). The
   free-slot ratios rather than a fixed `RUBY_GC_HEAP_0_INIT_SLOTS`,
   which held sockets swamp; they cost ~30% more RSS at 15K held. 4.0
   only: they don't size a 4.1 Ractor's own heap.

Target for items 4–7 together: objects per connect well under half of
today's 928, and k up by 4× or more. That puts 25K's refill near 20 s.

### Huge apps (25K+): divide held

8. **Several WS processes.** Both transports (`websocket_postgres`,
   `websocket_redis`) already fan out across processes, so each process
   gets every broadcast. What's missing:
   - `Server.new(reuse_port: true)`, which binds through `Socket` with
     `SO_REUSEPORT` (`TCPServer.new` binds at once, before an option can
     be set), so K processes share one port and the kernel spreads
     connects across them.
   - The deploying guide, saying when to add a process in the model's
     terms: past roughly N sockets per process, with N from the
     re-measured k.
   - The scaffold: how many to run (an env var read by the Procfile or
     process manager), defaulting to 1.

   This doesn't replace raising k: each process is still a Ractor
   server on all of its cores, and with a larger k, fewer of them are
   needed.

9. **Fewer Ractors per socket.** This is the one that changes the cost
   per socket rather than how often it's paid: N connection Ractors
   (one per core), each running many sockets as Fibers under a
   scheduler, instead of a Ractor per socket. It gives up "a crash only
   takes its own Ractor" (`history/plan-websocket.md`, Decision 3) for
   a rescue per Fiber. Large, and only worth it if item 10 says the cost
   is the Ractor's and not fixable upstream. Removing Live's relay
   thread alone isn't a small step: the socket's read and the port's
   `receive` block in two threads because nothing waits on both, so
   merging them needs the same scheduler.

### Upstream

10. **How much is Ruby's.** Done (see "Ruby 4.1"): on 4.0 the cost is
    per thread, and 4.1's per-Ractor GC removes it for other Ractors.
    What's left is following #22454 and #22455, and rerunning the matrix
    on each 4.1 preview and the release: held 0 / 5K / 15K, `--server-cpus`
    0 / 0-1 / 0-3, plus a churn step (sockets opened and closed
    continuously), recording global GCs and RSS.

### Not now

- **A signed connect ticket** (AnyCable's JWT, as the benchmark runs
  it): no database and no pool in the handshake; `reverify_interval:`
  still catches revoked sessions. Medium, needs an ADR. At these rates
  the pool isn't what limits; revisit if it shows up once GC doesn't.
- **WebSockets in Kino** (Rust): sockets, framing, pings and fan-out in
  Rust, with Ruby only deciding auth and policy. The largest change,
  and Kino's plan rather than Monk's.

## Proposed order

1. Done but for the VM run. Items 1–5, in one release, measured with
   `bin/benchmark_ws_connect` before and after (k and objects per
   connect, on 4.0), then on the benchmark's VM (S6 at a connect-rate sweep, 25K held). If phase 7
   can't wait for all of it, items 1–3 go first on their own.
2. Item 8, docs and `reuse_port:`, in the same release if it fits:
   it's small and independent of the rest.
3. Item 10's reruns on each 4.1 preview. If #22454 and #22455 are fixed
   for 4.1's release, the WS process recommends 4.1 and items 6, 7 and
   9 are dropped. If not, item 7 (the cheapest) for 4.0, then 6, and
   item 9 only if one 4.0 process at 25K held is still under the
   benchmark's 500/s or a restart's reconnect wave.

## Open questions

- **Broadcasts pay it too.** Any allocation in the WS process, a
  broadcast's included, triggers the same GC pauses at scale, so S7 and
  S8's delivery latency at 25K sockets likely carries them. To be
  checked with the benchmark's S7 at more sockets. Item 5's reused
  reply ports and item 6 help here as well.
- **The docs' 1,350/s** (`guides/persistence.md`, "Choosing a size")
  should be restated once this lands, in the model's terms: for a burst
  into an empty server, not for one already holding thousands.
- **Cores.** On 4.0, GC stops every Ractor and marks on one thread, so
  at scale a WS process uses about one core: the VM's ~7 ms per connect
  on 8 cores matches the model's prediction from 4, and the process
  never passed ~2.5 cores. More cores barely raise k; a faster core
  does, and so do more processes (item 8, while K ≤ cores). On 4.1,
  local GCs run in parallel, so cores should count again. Item 10's
  `--server-cpus` sweep confirms both.
