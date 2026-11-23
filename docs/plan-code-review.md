# 0.27: Code and test review — notes

Reviewed 2026-11-21 on `main_dev/v_0_27` at `13c3e3d`. Roadmap item 6, the
code and test suite review: fewer lines, best practice, test coverage.
**Review only: nothing has been changed.** Each finding says what it would
save and what it costs; each needs a yes or no before any work starts.

## The numbers

| | Lines | Of which code | Comments | Files |
|---|---|---|---|---|
| `lib/` (no templates) | 13,565 | 8,537 | 3,256 | 121 |
| Templates | 2,846 | | | 139 |
| `lib/` JavaScript | 742 (4 of them a vendored idiomorph) | | | 6 |
| `test/` | 24,372 | 17,999 | 1,601 | 140 test files |
| `test/` JavaScript (Node) | 343 | | | 3 |

- Suite: 1,548 runs, 0 failures, 0 skips, about 220 s.
- RuboCop: 50 offenses reported, 215 without `.rubocop_todo.yml`.
- Coverage (Ruby's `Coverage`, a run from the scratchpad, nothing added to
  the repo): **90.0% of lines, 79.7% of branches**. A floor, not the real
  figure: see T1.

The code is already tight. A scan for repeated code found one block of
six or more identical lines in all of `lib/`, and ten of four lines. So
"fewer lines" won't come from deleting duplicates. It can come from a few
shared pieces (L1–L4), from trimming comments (L5), and from the
`RateLimiter` decision (L6).

## `lib/`: fewer lines

**L1. The two fan-outs share their whole public surface.**
`websocket/pg_fanout.rb` (341 lines) and `websocket/redis_fanout.rb` (204)
both define `listen!` (the same shape: a Port, a subscriber Ractor, wait
for `:ok`, `Listeners.add`), `register`, `register_many`, `unregister`,
`unregister_many`, `count`, `ensure_listening!` and `disconnect_publisher`.
They differ only in how they subscribe, publish and frame the envelope.
- Change: a small module both include, with `subscribe`/`broadcast`
  left to each.
- Saves: about 40 lines, plus the comments that say "mirrors
  RedisFanout's ..." in both files.
- Risk: medium. It's Ractor code (what's shareable is passed to
  `Ractor.new`), but both have thorough tests.
- **Done 2026-11-23:** `websocket/fanout.rb` (62 lines) has `listen!`, the
  register/unregister/count methods and `ensure_listening!`; each class
  keeps `.subscribe`, `#broadcast`, `.disconnect_publisher` and names its
  `#subscriber_target`. PgFanout's ListenError now says "couldn't
  subscribe", like Redis's. Net 36 lines fewer.

**L2. Two identical error classes.** `CLI::Error` (`cli.rb:12`) and
`Generator::Run::UsageError` (`generator/run.rb:21`) are the same
seven-line class (a message plus `suggestion:`).
- Change: one, and the other an alias or subclass.
- Saves: about 7 lines. Risk: low.
- **Done 2026-11-23:** `CLI::Error` is `Generator::Run::UsageError`.

**L3. `Mail.deliver` and `Mail.deliver_later` build the message twice.**
`mail.rb:49` and `mail/deliver_later.rb:44`: the same default `from:`,
the same error when it's missing, the same `Message.new(...)`.
- Change: one private `message_for(...)`.
- Saves: about 6 lines. Risk: low.
- **Done 2026-11-23:** a private `Mail.message_for`.

**L4. The same network error list, four times.** `Net::SMTPError, IOError,
SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError` in
`mail/transports.rb:52` and `:64`, and the HTTP version in
`storage/backends/s3.rb:184` and `push/delivery.rb:77`.
- Change: a constant per module, or one shared list for HTTP.
- Saves: few lines, mainly one place to update. Risk: low.
- **Done 2026-11-23, SMTP only:** the rescue moved into `SMTP#session`,
  so no constant (net-smtp loads late). The HTTP list stays in push and
  S3: a shared constant would need a file loading net/http for both.

**L5. Comments are 28% of `lib/` (3,256 lines against 8,537 of code).**
Most explain why something must be the way it is for Ractors, which is
worth keeping. But some are history or cross-references:
- 165 comment lines name a plan, phase, step, decision or ADR;
- 25 say "mirrors X", "same reason as Y";
- 17 tell history ("discovered while building this", "found by").
- The most comment-heavy files: `websocket/server.rb` (217 comment
  lines, 272 code), `websocket/pg_fanout.rb` (144, 162),
  `websocket/connection.rb` (135, 170), `redis_fanout.rb` (88, 94).
- Change: one pass over the heaviest files, keeping each "why" and
  dropping the story of how it was found (the plan in `history/` keeps
  that).
- Saves: maybe 300–500 lines. Risk: none to behaviour; it's judgment on
  every paragraph.
- **Decided 2026-11-21: done together, file by file, as the last item.**

**L6. `Monk::Auth::RateLimiter` (46 lines, plus a 42-line test).** Nothing
in `lib/` uses it since 0.22: the login-email limit moved to the database
(`allow_login_request?`). `auth.md:192` still offers it for a per-IP
limit, "approximate but enough to slow a flood".
- Option: drop it and document the pattern (a `StateRactor` counter, or
  a Redis/Postgres one) in `auth.md`, per "documented patterns over new
  API".
- Saves: 88 lines. Risk: an app that uses it breaks: an upgrade note.
- **Decided 2026-11-21: left as it is for now.**

**L7. "Outside development and test" is written three ways.**
`Monk.env.development? || Monk.env.test?` in `push.rb:171`,
`storage.rb:172,182` and `auth.rb:368`; `%w[development test].include?`
in `settings.rb` (from the boot checks); and plain `!development?` in
other modules.
- Change: either one `Monk.env.local?` (development or test), or just one
  spelling.
- This ties in with the per-environment table in `settings.md`:
  deciding which modules treat test like development is a docs question
  as much as a code one.
- Saves: almost nothing. Gains: one rule, easy to search for. Risk: low.
- **Done 2026-11-21:** `Monk.env.development? || Monk.env.test?` is the
  one spelling; `settings.rb` now uses it too. The modules that relax
  only in development (`!Monk.env.development?`) stay as they are, on
  purpose.

**L8. Repeated initial state in `reset!`.** Modules like `Live`
(`live.rb:21` and `:99`) set their ivars eagerly at the top, then repeat
the same assignments in `reset!`.
- Change: call `reset!` once in the module body. Just as eager, so it
  keeps the Ractor rule the comments ask for.
- Saves: about 3–5 lines per module, across `Live`, `Push`, `Presence`,
  `Storage` and others (to count). Risk: low.
- **Done 2026-11-23:** `reset!` in the body of `Live`, `Pwa`, `Views`,
  `Assets` and `Log`. `Push` keeps its one line; the other modules
  don't repeat their state.

## `lib/`: best practice

**B1. Nothing serious found.**
- No TODOs, no stray `puts` or `p`, no dead references to docs.
- No method that nothing calls. The ones only tests call are either
  public API an app calls (`require_user!`, `csrf_field`, `resources`,
  `find_all`) or named test seams (`Assets.unmount`,
  `Tracker#heartbeat_now!`).
- The broad `rescue StandardError` (34) and the three
  `rescue Exception` are in supervisors and Ractor loops, where they
  keep a process alive. Each was looked at, none is hiding a bug.

**B2. `Persistence::Pg.make_portable` reaches into `pg`'s internals**
(`persistence/pg.rb:78`: `instance_variable_set(:@connection, nil)` on a
`PG::Error`).
- It works, and its comment says why. But a `pg` release that renames
  those ivars would break it silently.
- Change: a test that fails if a `PG::Error` still holds a connection
  after `make_portable` (maybe there already is one: to check).
- **Checked 2026-11-23, nothing to add:**
  `test_a_pg_error_keeps_its_class_message_and_diagnostic_fields` asserts
  the connection is gone and the result is an `ErrorResult`.

**B3. Small RuboCop offenses in `lib/`:** `auth/helpers.rb:43`,
`base.rb:370` (line too long), `context.rb:67`. Autocorrectable or
one-line fixes.

## Tests

**T1. Coverage can't see Ractors or subprocesses, so 90% is a floor.**
- The low files are the Ractor ones: `persistence/pool.rb` 34%,
  `presence/counts.rb` 37%, `presence/reactor.rb` 54%, `jobs/worker.rb`
  54%, `websocket/server.rb` 55%, `websocket/registry.rb` 58%, and
  `bin.rb` 65% (it runs in spawned scripts).
- Checked on the pool: its missed lines are `Dispatcher.run` and the
  worker bodies, which run inside Ractors. Its 40 tests do run them.
- So: no coverage target for those files. The figure to watch is
  main-Ractor code, already 95%+ in most files.

**T2. Real gaps in main-Ractor code**, the ones coverage can see:
- **`Monk::Storage.check` and the File backend's `check` (`storage.rb:126`,
  `storage/backends/file.rb:143`) have no test.** Mine, from yesterday.
- The File backend's error paths: the seven `RequestError`/`NotFoundError`
  raises in `get`, `head`, `delete`, `copy` and `receive`.
- Storage routes refusing a bad signature (`storage/routes.rb:30, 33`) and
  a missing object (`:71`). Security-relevant, so worth a test each.
- `Push::Subscription` refusing a non-https endpoint
  (`push/subscription.rb:41`). Security-relevant.
- `Mail::MIME` refusing text that can't become UTF-8 (`mail/mime.rb:120`).
- `Persistence`: an unknown database name (`persistence.rb:45`), and
  `start_pools!` outside the main Ractor (`:90`).
- `Base.freeze!` naming an error handler that isn't shareable
  (`base.rb:138`).
- `Presence.online?` (`presence.rb:42`) and its `grace:` check (`:49`).
- `Live::Publisher` refusing a topic that isn't a String or Symbol
  (`live/publisher.rb:84`).
- The CLI's `help --file` for a file the module doesn't write
  (`cli.rb:253`), and the plural "Unknown modules" (`generator/run.rb:65`).
- `Jobs::Runtime`'s supervisor logging when it can't reconnect or
  deregister (`jobs/runtime.rb:132, 171, 203, 235`): harder to reach,
  lower value.
- Change: about 15 small tests. Worth it for the security ones and the
  two `check`s; the rest are a nice-to-have.
- **Done 2026-11-23:** 11 tests, everything above but the Jobs
  supervisor logging. Found on the way: `Backends::File#delete`'s rescue
  can't run (`FileUtils.rm_f` swallows errors): removed.

**T3. One test is a quarter of the suite.**
`GeneratorsCombinationsTest#test_every_combination_works` takes 54 s of
215. It generates every pair of the 11 modules (twice over for websocket
and live, once per transport), about 74 apps, and runs each one's
`bin/setup_db` and own tests in subprocesses.
- Options:
  - run the pairs in parallel (each already has its own database);
  - run only the two "all modules" apps by default, and pairs under
    `SLOW=1`, which already runs every size;
  - or keep it as it is: it's the one test that proves every pair works.
- Generator tests are 90 s in all; the browser tests 47 s.
- **Done 2026-11-21 (option A):** the pairs grid and `SLOW=1` are gone.
  `INTERACTING` lists the six sets whose code looks for another module
  (jobs+mail, jobs+auth, websocket+auth, live+auth, presence with and
  without live), run with the two full sets: 8 apps, 54 s down to 7.5 s.
  Checked by planting a bug in `recurring.rb`'s auth sweep line: the
  jobs+auth set failed on it.

**T4. The Postgres and Redis versions of the same tests are written
twice.**
- `live_pg_test.rb` (146 lines) and `live_redis_test.rb` (127) share 3
  test names and their helpers (`connect_and_subscribe`, `unique_topic`,
  the WS process).
- `websocket_pg_fanout_test.rb` (533) and `websocket_redis_fanout_test.rb`
  (212) share 6.
- `live_multiprocess_helpers.rb` and `_pg.rb` repeat `stop_ws_process`.
- Change: a shared contract module per pair, like
  `test/support/storage_contract.rb` already does for the storage
  backends.
- Saves: maybe 150–250 lines, and a new transport would get every test
  for free. Risk: low.
- **Done 2026-11-23:** `test/support/fanout_contract.rb` (12 tests) and
  `live_fanout_contract.rb` (7), on hooks each transport defines;
  `support/live_multiprocess.rb` starts and stops the WS process for both.
  Every test now runs on both transports. 333 lines fewer.

**T5. Repeated setup across the jobs and auth tests.** Six jobs test
classes repeat the same `setup` (`Persistence::Pg.reset!`, register, skip
guard, `setup_jobs_tables`); four auth ones the same for auth tables.
- Change: a `JobsTestHelpers#setup_jobs_db` (and one for auth) in
  `test_helper.rb`.
- Saves: about 40 lines. Risk: low.

**T6. Signed bucket requests are written three times.** The S3 backend's
`request` (which takes `query:` since `Storage.check`),
`StorageTestHelpers#bucket_request` and `bin/storage_check#bucket` all
sign a bucket request with SigV4.
- Change: the two outside `lib/` could share one helper, or call the
  backend's, if it stops being private.
- Saves: about 30 lines. Low value: `bin/storage_check` is a dev tool.

**T7. 64 fixed `sleep`s in tests, most short.** The longest:
- one of 4 s, one of 2, four of 1.5, one of 1.2, two of 1;
- in `presence_reactor_process_test`, `live_client_network_browser_test`,
  `persistence_pool_test`, `jobs_process_test`, `websocket_heartbeat_test`,
  `websocket_ractor_integration_test` and `live_client_browser_test`.
- Each one is a wait that could be a condition (`wait_until`), faster and
  less flaky on a slow machine.
- Change: look at the ones of 1 s or more first. Risk: low; a wrong
  condition shows up as a failure, not a silent pass.

**T8. 21 tests have no assertion of their own.**
- Some wait in a helper that fails on timeout, which is fine.
- Others pass if nothing raises (for example
  `settings_test.rb#test_public_url_accepts_real_hosts_localhost_and_ips_in_production`,
  mine). That's a valid test, but the intent is clearer with a comment,
  or an assertion on the result.
- Low priority.

**T9. The JS has no coverage figure.** Its pure logic is tested by Node
(`protocol.js`, push state, the service worker's click), and the rest by
headless Chrome (`monk_live.js` 365 lines, `push.js` 132). Fine as it is;
noted only.

## Tooling

**R1. `.rubocop_todo.yml` (400 lines) is stale.**
- It names three files that are gone: `lib/monk/scaffold.rb`,
  `monk.gemspec`, `test/scaffold_test.rb`.
- It hides 165 offenses: most are safe autocorrections
  (`Naming/BlockForwarding` 8, `Style/BisectedAttrAccessor` 8,
  `Style/IfUnlessModifier` 6, trailing whitespace 5, ...), plus five
  `Lint/SuppressedException` worth a look one by one.
- Change: regenerate it, then work it down, or remove it once the
  offenses are fixed.
- **Done 2026-11-21, with R2 and B3:** the todo file is gone and RuboCop
  reports no offenses on 282 files. Safe autocorrections, each `lib/`
  change read; one was wrong and is reverted (`views.rb`'s
  `module_eval` kept the template's own path, or template errors would
  point at `views.rb`), and one mangled a line of
  `bin/benchmark_ws_connect`, rewritten by hand. The rest by hand or by
  config (`.rubocop.yml`): short parameter names (`op`, `n`, `qr`,
  `if`), status codes in test names, route blocks in tests, one-file
  `bin/` scripts.

**R2. The 50 visible offenses.**
- 24 are in `bin/benchmark_ws_connect`, a dev tool still referenced by
  the active plans.
- 23 are in tests from 0.26 (`params_parsing_test.rb` 7, `flash_test.rb`
  4, `auth_cookie_flow_test.rb` 3, ...).
- 3 are in `lib/` (B3).
- 34 are autocorrectable. The 7 `Naming/VariableNumber` in
  `params_parsing_test.rb` are test names with numbers in them, maybe
  better allowed than renamed.

**R3. No CI.** Everything above was run by hand. Already noted in the
Ruby 4.1 plan (a 4.0/4.1 matrix); a CI would also run RuboCop.

## Suggested order

1. **Quick and safe:** R1 and R2 (RuboCop), B3, L2, L3, L4, L8. Small diffs,
   no behaviour change.
2. **Tests that matter:** T2's security and `check` ones, then B2.
3. **Larger refactors, one commit each:** L1 (fan-outs), T4 (contracts),
   T5 (setup helpers).
4. **Your decisions first:** L6 (`RateLimiter`), L7 (one spelling or
   `Monk.env.local?`), T3 (the combinations test), L5 (comment trimming,
   file by file).
5. **Last, if time allows:** T7 (sleeps), T8, T6.

Rough total if all of it is done: `lib/` about 400–600 lines shorter
(mostly L5), tests about 250–350 shorter, and about 15 new small tests.
