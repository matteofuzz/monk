# Plan: Ruby 4.1 compatibility

Status: assessed 2026-10-14 against Ruby 4.1.0-preview1 (released
2026-10-12, `ruby 4.1.0preview1 (2026-10-11 master 2d08b5f42f)`). Fixes
4.1, 4.2 and 4.3 are done on `main_dev/ruby-4-1` (one commit each). Kino
0.7.1 and net-protocol 0.4.0 are in the local lockfile, which is
gitignored. Full suite on both Rubies: 1047 runs, 0 failures. The only skip
is the TLS probe; 4.1.0-preview1 has 0 browser skips once net-protocol is
updated. Section 4.4 is still open. Monk requires `>= 4.0`.

**Verdict: 4.1-compatible, verified on preview1, not yet "4.1 ready".**
Everything gets rechecked at the official 4.1 release; section 7 lists
what's left. This plan stays active until then.

## Summary

- Monk needs two small code fixes for 4.1, and a third fix for a pool hang
  that already exists on 4.0. No other Ractor code is affected.
- The test suite on 4.1, run without Kino: 1045 runs, 32 failures, 1 skip,
  and 1 test that hangs. One failure and the hanging test come from 4.1
  changes. The other 31 failures are only there because Kino 0.4.0, the
  version Monk's `Gemfile.lock` pins, doesn't build on 4.1.
- **Kino is already fixed upstream:** 0.7.1 (2026-09-25) builds on 4.1 and
  serves in ractor mode. Monk only needs `bundle update kino`. Newly
  scaffolded apps already get 0.7.1, because their Gemfile doesn't pin Kino.
  After the update, the generator tests pass on 4.1 (section 4.5).
- Per-Ractor GC is the main gain 4.1 brings Monk, and needs no code change.

## 1. What 4.1 changes for Ractors

From the release notes and NEWS:

| Change | Kind |
|---|---|
| Per-Ractor GC: each Ractor's heap is collected on its own thread, without stopping the others. Stop-the-world only for an explicit full GC or reclaiming dead Ractors' heaps | Performance |
| `GC.start(global: false)` forces a Ractor-local GC. Plain `GC.start` stays global | New API |
| `Ractor#value` returns the value only once. A second call raises `Ractor::Error` | Breaking |
| `Ractor#monitor` sends `[ractor, :exited]` / `[ractor, :aborted]` instead of the bare Symbol | Breaking |
| `ObjectSpace.define_finalizer` on another Ractor's object raises `Ractor::IsolationError` | Breaking |
| C API: Ractor-scoped GC address registration | C extensions |

Found by running the suite. **Not in the release notes:**

| Change | Kind |
|---|---|
| `Ractor.make_shareable` on a Proc that writes an outer variable raises `Ractor::IsolationError`. 4.0 raised `ArgumentError` with the same message | Breaking |

Checked with a direct script:

```ruby
x = 0
Ractor.make_shareable(nil.instance_eval { proc { x += 1 } })
# 4.0.6:          ArgumentError
# 4.1.0-preview1: Ractor::IsolationError
# both: "can not make a Proc shareable because it accesses outer variables (x)."
```

## 2. Impact on Monk, call site by call site

### `Ractor#value` returning only once: no impact

Every Ractor's `value` is read once:

- `lib/monk/jobs.rb:269` (`perform_in_ractor`): `Ractor.new { ... }.value`,
  once.
- `lib/monk/jobs/runtime.rb:202` (`worker_exited`): the monitor entry is
  deleted from `@monitors` before `value` is called, so the same worker can't
  be read twice.
- `lib/monk/persistence/pool.rb:341` (`stop_workers`) uses `join`, not
  `value`.
- About 20 tests call `.value` once on a fresh Ractor.

All of these passed on 4.1.

### `Ractor#monitor` message: one log line, and a hang it exposed

Two places use `monitor`:

- `lib/monk/jobs/runtime.rb:187-205`: one port per worker. `supervise` and
  `shut_down` tell workers apart by which port fired and ignore the message.
  **No impact.** The comment at `:194` ("Ractor#monitor's message is a bare
  :exited or :aborted that doesn't say which Ractor") is no longer true on 4.1.
- `lib/monk/persistence/pool.rb:299` (`watch`): forwards the message as
  `reason` to `died` (`:310`), which logs it:

  ```
  4.0: pool :p: worker 0 died (aborted) while running PoolTestCalls.die, ...
  4.1: pool :p: worker 0 died ([#<Ractor:#3 monk-pool-p-0 .../pool.rb:283 terminated>, :aborted]) while running ...
  ```

  `test/persistence_pool_test.rb:514` asserts `died \(aborted\)`, so
  `test_a_worker_that_dies_mid_call_fails_that_call_at_once_and_is_replaced`
  fails on 4.1. That failure then makes the suite hang (section 3).

### `define_finalizer` across Ractors: no impact

Monk calls neither `ObjectSpace.define_finalizer` nor any other
`ObjectSpace` method.

### C API GC registration: no impact on Monk itself

Monk is pure Ruby. Its native dependencies may be affected:

- **Kino 0.4.0** (the pinned version) **fails to build**. Its Rust bindings
  (`magnus`, on `rb-sys` 0.9.128) don't know a field 4.1 added to
  `rb_data_type_t`:

  ```
  error[E0063]: missing field `handle_weak_references` in initializer of ...
  error: could not compile `magnus` (lib) due to 2 previous errors
  ```

  **Kino 0.7.1 fixes it.** Its CHANGELOG: "Updated Magnus to 0.9", "now
  tested against Ruby HEAD", and "Fixed a crash on Ruby 4.1 in ractor mode:
  with Ruby's new per-ractor GC, a worker ractor could collect cached env
  strings and large response bodies that other ractors were still using".
  Checked on 4.1.0-preview1: `gem install kino -v 0.7.1` compiles from
  source (magnus 0.9.0, rb-sys 0.9.130) and loads. `kino -m ractor -w 2`
  then served 989 of 989 requests with 200 and a 50 KB body; 11 requests
  sent before boot finished were refused. Then it drained cleanly on TERM.
  So Kino needs no issue. Monk's `Gemfile.lock` still pins 0.4.0 and needs
  `bundle update kino`. Scaffolded apps' Gemfiles have an unpinned
  `gem "kino"`, so new apps already resolve to 0.7.1.
- **pg 1.6.3**: the precompiled `arm64-darwin` gem has no 4.1 binary.
  Bundler compiled it from source without errors, and the pool, persistence,
  jobs, Live and fanout tests all pass on it.
- **redis**: installed and passed the Redis fanout and Live tests.

### `make_shareable` error class: wrong error at boot

`lib/monk/base.rb:98-111` (`Monk::Base.freeze!`) rescues only `ArgumentError`
around `Ractor.make_shareable(route[:block])` and the error handlers. On 4.1 a
route like `get("/hits") { count += 1 }` makes boot fail with a raw
`Ractor::IsolationError` instead of `Monk::UnshareableRouteError` naming
`GET /hits`. Caught by
`BootTest#test_freeze_raises_precise_error_naming_the_offending_route`.

These sites already rescue both classes, so they're fine:
`lib/monk/auth.rb:55`, `lib/monk/state_ractor.rb:26`,
`lib/monk/websocket/server.rb:126`, `lib/monk/live/policy.rb:84`.
`lib/monk/mail.rb:98` and `lib/monk/live/renderer.rb:34` rescue
`IsolationError` only, which is what both versions raise in their case.

### Per-Ractor GC: an improvement

Request, WebSocket, job and pool Ractors all allocate per message. On 4.0 any
GC pauses all of them. On 4.1 each collects alone. Benchmarking that
difference fits Monk's "Ractors at scale" goal; see 4.4.

`test/websocket_pg_fanout_test.rb:278` uses `GC.disable` / `GC.enable`. That
passed on 4.1.

## 3. The pool shutdown hang (already on 4.0, exposed by 4.1)

Seen as: the whole suite stops making progress (0% CPU) inside
`PersistencePoolTest`. It reproduces every time when that test is run alone.

Traced with a scratch file of `prepend`s, which left the repo untouched:

1. The worker dies running `PoolTestCalls.die`. The dispatcher's `died`
   answers the caller `:died`, logs the death, and calls `spawn_worker(0)`.
2. On 4.1 the log assertion (`:514`) fails, so the test ends at once and
   `teardown` → `Pg.reset!` → `stop_pool` sends `[:stop]` and calls `join`
   on the dispatcher (`lib/monk/persistence.rb:216-222`).
3. The replacement worker is still in `backend.checkout`. It hasn't sent
   `[:ready, index, port]`, so the dispatcher has no port for it
   (`@workers[0][:port]` is nil).
4. `stop_workers` (`pool.rb:334`) does `worker[:port]&.send(:stop)`, which is
   skipped because the port is nil, then `worker[:ractor].join`.
5. The worker finishes connecting and sends `[:ready]` and `[:idle]` to an
   inbox nobody reads anymore. Then it blocks in `port.receive` waiting for
   a call. It never gets `:stop`, so the dispatcher's `join` never returns,
   and neither does the test's `join` on the dispatcher.

On 4.0 the assertion passes. The test then makes one more `pool.call`, which
waits for the replacement to be ready, so teardown always finds every worker
with a port. Any shutdown that lands while a worker is connecting hangs the
same way on 4.0: right after a replacement, or during a retry with backoff
(`retry_later`). Production never stops a pool; this path is test-only
(`reset!`). The risk is a test suite that hangs, not a server.

Proof that this is the whole story: with only `reason` normalized (scratch
`prepend` of `died` with `Array(reason).last`), all 39 tests in
`persistence_pool_test.rb` pass on 4.1 in 9 s.

Two quick checks that `monitor` itself behaves on 4.1:

- A thread monitoring a Ractor while another thread `join`s it works the
  same as on 4.0, both inside a Ractor and in the main Ractor.
- `monitor` from a Thread inside a Ractor delivers `[ractor, :aborted]`
  correctly.

## 4. Fixes

Ordered by priority. 4.1-specific fixes must keep working on 4.0, since
the gemspec keeps `>= 4.0`.

### 4.1 `Monk::Base.freeze!`: rescue both error classes

`lib/monk/base.rb:101` and `:109`: `rescue ArgumentError,
Ractor::IsolationError => e`, as the other four sites already do. Fixes
`BootTest` on 4.1.

### 4.2 Pool `died`: log the same reason on both versions

`lib/monk/persistence/pool.rb`: in `watch` (`:304`) or `died` (`:310`), take
`Array(reason).last`. That gives `:aborted` / `:exited` on 4.0 and 4.1.
Fixes the log line and `:514`.

### 4.3 Pool `stop_workers`: stop a worker that is still connecting

Fix the hang itself, so it can't come back from another test failure or a
stop during backoff. Options:

- **a. (Recommended)** Before joining, also read the inbox until every worker
  with no port has sent `:ready` or `:failed` (the `start_workers` loop
  already does this). Then send `:stop` to the ports that arrive. The
  worker's connect has a timeout, so this wait is bounded.
- b. Have the worker check a stop flag after `checkout` before entering its
  loop. This needs a shareable signal, so it's more moving parts.
- c. In `stop_workers`, skip `join` for workers with no port. This leaks a
  Ractor blocked forever, so it hides the problem rather than fixing it.

Test: start a pool whose connect is slowed down (the TCP proxy in
`test/support/tcp_proxy.rb`), kill a worker, and `reset!` while the
replacement is still connecting. It must return in time on 4.0 and 4.1.

### 4.4 Later, once 4.1 is the minimum (not now)

- `jobs/runtime.rb`: one shared monitor port instead of one per worker,
  matching on the message's Ractor. Update the comment at `:194`.
- `pool.rb` `watch`: one monitor port read from the dispatcher instead of a
  Thread per worker.
- Benchmark per-Ractor GC: `bin/benchmark_router` and a WebSocket fan-out
  load, 4.0.6 against 4.1, looking at p99 latency under allocation-heavy
  handlers.

Both monitor changes need either `required_ruby_version >= 4.1` or a
branch on the message's shape. Not worth it before 4.1 is final.

### 4.5 Kino (done locally: lockfile on 0.7.1)

- `bundle update kino` in the repo (0.4.0 → 0.7.1), then run the suite on
  4.0.6 to check that 0.4 → 0.7 brings no regressions. 0.7.0 added an
  elastic worker pool, which stays off unless `max_workers` is set.
- Then rerun the full suite on 4.1, generator and `exe/monk` tests
  included. The 31 Kino-only failures should go away.
- Consider `gem "kino", ">= 0.7.1"` in `lib/monk/templates/base/Gemfile`,
  so an app with an old lockfile can't stay on a Kino that fails on 4.1.
  That's also a line for the upgrade guide.

### 4.6 net-protocol in the lockfile (done locally)

On 4.1, all 19 browser tests were skipped ("Ferrum/Chrome not available").
Ferrum's `Net::HTTP` call crashed: 4.1's default `net-http` 0.10.0 calls
`BufferedIO#readuntil(..., limit:)`, but the lockfile pinned the
`net-protocol` gem at 0.2.2 (pulled in by `net-smtp`), which overrides the
default gem and predates `limit:`. `bundle update net-protocol
--conservative` → 0.4.0, the default gem on both 4.0.6 and 4.1. Monk's
`lib/` doesn't use `net/http`, and mail over SMTP passed with both versions.
An app whose lockfile still pins `net-protocol` 0.2.2 breaks any
`Net::HTTP` request on 4.1: that's a line for the upgrade guide.

## 5. Full 4.1 test results (before the fixes)

Run with `--seed=1`, the hanging test excluded
(`--exclude=/test_a_worker_that_dies_mid_call/`), Kino left out of the
bundle:

```
1045 runs, 3132 assertions, 32 failures, 0 errors, 1 skips
```

| Failures | Cause |
|---|---|
| 28 | Generator and `exe/monk` tests: the generated app's `bundle` can't find `kino` |
| 3 | `GeneratorsWebSocketServerTest`: "bin/websocket_server exited at boot", same cause (it boots with `BUNDLE_GEMFILE` = the repo's Gemfile, which includes Kino) |
| 1 | `BootTest#test_freeze_raises_precise_error_naming_the_offending_route`: 4.1 (fix 4.1) |
| hang | `PersistencePoolTest#test_a_worker_that_dies_mid_call_...`: 4.1 + latent bug (fixes 4.2, 4.3) |

The 1 skip is the TLS probe test (the test Postgres has `ssl = off`), the
same as on 4.0.

Everything else passed on 4.1: jobs (runtime, PG adapter, drain,
recurring), persistence pool and integration, WebSocket (registry, server,
PG and Redis fanout), Live, auth, mail, settings, views, routing.

## 6. How to reproduce

Until the lockfile moves to Kino 0.7.1, the repo bundle includes Kino 0.4.0,
which doesn't build on 4.1. So use a Gemfile outside the repo that has only
the gemspec:

```sh
mkdir -p /tmp/monk41
printf 'source "https://rubygems.org"\ngemspec path: "%s"\n' "$PWD" > /tmp/monk41/Gemfile
export RBENV_VERSION=4.1.0-preview1 BUNDLE_GEMFILE=/tmp/monk41/Gemfile
bundle install
bundle exec rake test TESTOPTS="-v --seed=1 --exclude=/test_a_worker_that_dies_mid_call/"
```

The hang alone (stop it with Ctrl-C):

```sh
bundle exec ruby -Ilib:test test/persistence_pool_test.rb \
  -n test_a_worker_that_dies_mid_call_fails_that_call_at_once_and_is_replaced
```

## 7. Readiness: what's verified, and the recheck at the 4.1 release

### Verified on 4.1.0-preview1 (2026-10-14)

- Full suite, after the fixes, with Kino 0.7.1 and net-protocol 0.4.0
  (macOS arm64, local Postgres and Redis):

  | Ruby | Runs | Failures | Skips |
  |---|---|---|---|
  | 4.0.6 | 1047 | 0 | 1 (TLS probe) |
  | 4.1.0-preview1 | 1047 | 0 | 1 (TLS probe) |

- The generator tests run real scaffolded apps under Kino on 4.1, so a new
  app works on 4.1 locally.
- Every Ractor change in the release notes has been checked against Monk's
  call sites, plus the one the notes miss (`make_shareable`'s error class).
- 4.0.6 still passes. Monk supports both, and the gemspec stays `>= 4.0`.

### Not verified yet

1. **Final release.** This was a preview, and the Ractor API is still
   officially experimental (Ruby warns about it at every `Ractor.new`).
   Later previews, the RC or the final release can still change it.
2. **Linux / Docker.** Only macOS arm64 was tested, but apps deploy on
   `ruby:*-slim` (Linux). The repo has no CI to cover it.
3. **Load.** The suite only checks that things work. Per-Ractor GC is the
   biggest runtime change in 4.1, and Kino 0.7.1 had to fix a ractor-mode
   crash that only showed under load. No sustained load has run on 4.1.
4. **Apps.** The scaffold templates still pin 4.0, and an existing app
   needs dependency updates (below).

### Recheck at the official 4.1 release (expected 2026-12-25)

Do these in order. They're all needed before we call Monk "4.1 ready".

1. **Read the final NEWS** for Ractor, GC, `net-*` and C API changes made
   since preview1. Diff it against section 1 and redo section 2 for anything
   new.
2. **Full suite on 4.1 final and 4.0.x**, with the repo's real Gemfile
   (`.ruby-version` on 4.1 final; the commands are in section 6 without the
   scratch Gemfile). Expect 1047+ runs, 0 failures, only the TLS skip. If any
   browser tests are skipped, check `net-protocol` first (4.6).
3. **Update the dependencies, then rerun 2:** `bundle update kino
   net-protocol` (and `pg`/`redis` if they ship 4.1 binaries). Check the
   Kino CHANGELOG for 4.1 notes after 0.7.1.
4. **Linux / Docker:**
   - Build the scaffolded app's Docker image on `ruby:4.1-slim`, boot it,
     and serve requests (HTTP, WebSocket, Live) against Postgres and Redis.
   - Run Monk's suite in a `ruby:4.1` container too. This is a good moment
     to add CI with a 4.0 / 4.1 matrix.
5. **Load test:**
   - Run `bin/benchmark_router` and a WebSocket fan-out load on 4.0 and 4.1,
     long enough (10+ minutes) for many GC cycles, with allocation-heavy
     handlers.
   - Look for crashes, memory growth and p99 latency. Per-Ractor GC should
     improve p99.
   - Also run a jobs process (`bin/jobs`) and the pool under load, since
     both start, monitor and replace Ractors.
6. **Templates** (`lib/monk/templates/base/`):
   - `.ruby-version` 4.0.6 → 4.1.x;
   - `Dockerfile` `ruby:4.0-slim` → `ruby:4.1-slim` (both stages);
   - `Gemfile`: `gem "kino", ">= 0.7.1"`, so an old lockfile can't keep a
     Kino that doesn't build on 4.1;
   - rerun the generator tests.
7. **Upgrade guide** (`docs/guides/upgrading.md`), for existing apps:
   - Kino ≥ 0.7.1: older versions don't compile on 4.1 (magnus).
   - `net-protocol` ≥ 0.4.0: with 0.2.2 locked, every `Net::HTTP` request
     crashes on 4.1 (`readuntil` and `limit:`, 4.6).
   - `.ruby-version` and Dockerfile base image.
   - A route block that writes an outer variable still fails boot with
     `UnshareableRouteError`; nothing to do, but the underlying Ruby error
     class changed.
8. **Decide section 4.4** (shared monitor ports, raising the minimum to
   4.1) based on the load results. Not needed for compatibility.
9. **Docs:** README / roadmap mention 4.1 support, CHANGELOG entry, and
   move this plan to `docs/history/` with the historical banner.

## Sources

- [Ruby 4.1.0-preview1 Released](https://www.ruby-lang.org/en/news/2026/10/12/ruby-4-1-0-preview1-released/)
- [NEWS for Ruby 4.1](https://docs.ruby-lang.org/en/master/NEWS_md.html)
- [ruby/ruby releases](https://github.com/ruby/ruby/releases)
