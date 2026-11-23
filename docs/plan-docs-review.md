# 0.27: Docs review — notes

Started 2026-11-23 on `main_dev/v_0_27`. Roadmap item 6, "a review of all
the docs for clarity": README, guides, ADRs, SETUP.md and the scaffold's
templates, easy to follow for someone new to Monk, consistent with each
other and with the code as it is now, and without outdated references.
**Review only: nothing changed until each finding has a yes or no.**

## The numbers

About 13,000 lines of Markdown outside `docs/history/`:

| | Files | Lines |
|---|---|---|
| README | 1 | 99 |
| Guides (`docs/guides/`) | 22 | 4,601 |
| ADRs | 19 | 487 |
| Design docs (`docs/design/`) | 7 | 2,796 |
| Active plans (`docs/plan-*.md`) | 6 | 2,002 |
| Other (`deployment-options`, `mail-providers`, `framework-comparison`, `roadmap`, `development`, ...) | 6 | 1,446 |
| CHANGELOG | 1 | 1,385 |
| Scaffold `setup.md` / `agents.md` sections | 26 | 951 |

Checked by script: **no broken relative link or anchor** in any of them.

## Structure

**S1. Finished plans still in `docs/`.** The rule is `docs/plan-*.md`
for active plans, `docs/history/` for finished ones.
- `plan-digest-preload.md` (0.22.2): done; its "Open" is an upstream
  issue to file, nothing in Monk.
- `plan-boot-settings-checks.md` (0.27): done; moves at the release.
- `plan-live-networks-presence.md` (0.24) and `plan-ws-connect-ceiling.md`
  (0.22.1): built and released, but each still has steps only you can
  run (A0 on real phones; the VM run and the benchmark's sweep).
- Change: move `plan-digest-preload.md` now; for the other two, either
  move them with their open items copied to the roadmap, or keep them
  while those items are open.
- **Done:** all three moved, every path to them updated (CHANGELOG,
  guides, ADR 0019, tests, `bin/benchmark_ws_connect`; dropped from the
  two Live client JS comments, as L5 did in `lib/`). The open steps of
  the last two are in the roadmap's new "Open checks".

**S2. `docs/deployment-options.md` is a September research note.** It
compares hosts for an app with Postgres, Redis and SMTP, from before
`Monk::Mail`, `monk add deploy` and the Hetzner guide; two "Update" notes
patch it. `deploying.md` and `deploy-hetzner.md` now say what it was
looking for. Linked from `CHANGELOG.md` and `mail-providers.md` only.
- Change: move it to `docs/history/`, links updated.
- **Done:** moved; the paths in `mail-providers.md` and the CHANGELOG
  updated.

**S3. Design docs carry their own status banners**, some current
("implemented", linking the guide), some not (`live-pg-fanout.md`:
"design exploration, 2026-09-24", though it shipped in 0.16;
`ws-horizontal-scaling-considerations.md`: "notes"). To check each one
in round 7.

## README

**R1. The "Status" section is the release history again**: one
paragraph of about 1,000 words, 0.17 to 0.26, which the CHANGELOG
already holds. A newcomer reading top to bottom meets it as the last
thing, and it still says `monk new --live --postgres`, a flag removed in
0.21.
- Change: "pre-1.0, the API may still change between minor versions",
  then pointers to the CHANGELOG and the roadmap. About 15 lines fewer
  on screen, nothing lost.
- **Done:** one paragraph: pre-1.0, then the CHANGELOG, `upgrading.md`
  and the roadmap.

**R2. "More documentation" describes `docs/design/` as "design docs and
phase-by-phase plans behind each feature"**, and lists five of the seven.
- Change: one line per kind (guides, design docs, ADRs, history), not a
  partial list.
- **Done:** guides (with the three for running an app), design docs
  (start with `ractor.md`), ADRs and `CONTEXT.md`, the framework
  comparison, history, CHANGELOG.

**R3. `gem "monkrb", "~> 0.26"`** in Quick start: becomes `~> 0.27` at
the release, with the version bump (a release step, not a finding).

## Roadmap

**M1. The 0.27 bullet still says "`WS_ALLOWED_ORIGINS` missing
`PUBLIC_URL`"**: since 0.27, `PUBLIC_URL` is always allowed and
`WS_ALLOWED_ORIGINS` lists only extra origins.
- Change: describe what 0.27 refuses (`allowed_origins` that aren't
  origins), and mark the 0.27 items done as they are.
- **Done:** the first bullet says what boot refuses now; five of the
  six 0.27 items say "Done", the docs review doesn't yet.

## Reading, for clarity

The rest needs reading, not a script. Proposed rounds, each ending with
its findings here and your yes or no before any change:

1. **Getting started:** README (beyond R1–R3), `scaffolding.md`, the
   `base` module's `setup.md` and `agents.md` (what a new app shows
   first).
2. **Core guides:** routing, forms, boot and shared state, settings,
   views, logging.
3. **Data and identity:** persistence, migrations, auth, mail.
4. **Real time:** jobs, websocket, live, presence.
5. **Files and devices:** storage, pwa, push.
6. **Running it:** deploying, deploy-hetzner, upgrading, development.
7. **Decisions and background:** ADRs, design docs' banners (S3),
   `CONTEXT.md`, `mail-providers.md`.

For each guide, the questions: can someone new follow it top to bottom;
does every example match the code and the templates as they are now;
does it repeat another guide, or contradict it; does it point to plans
or history a reader doesn't need.

## Round 1: getting started

Read: README, `docs/guides/scaffolding.md`, the base module's `setup.md`
and `agents.md`. Checked against the code: module dependencies
(`depends_on`), `config/load.rb`'s order, the exit codes, `monk help
--file`, the old flags, the base app's routes and page, the Dockerfile's
`MONK_ENV`, `bin/server`'s warning, the 415 for multipart, the README's
taste (`where`, `render` with locals, `error`). All of those match.

**G1. scaffolding.md's first paragraph lists the modules up to Live**
("Postgres, Redis, mail, auth, jobs, WebSocket, Live"), written in 0.21;
presence, storage, pwa, push and deploy came later.
- Change: "a Monk module (the table below)", no list to keep current.

**G2. scaffolding.md's module table links a guide for four modules**
(presence, pwa, push, deploy) and not the others, though each but redis
has one.
- Change: a guide link for every module that has one.

**G3. scaffolding.md's tree in "What every app looks like"** leaves out
`config/recurring.rb` (jobs), the `.env` files, `Dockerfile`, and deploy's
`compose.yaml`, `Caddyfile`.
- Change: add them, each with the module that writes it.

**G4. The README's paragraph on `monk new` and `monk add`** (Quick start)
is one sentence of about 120 words: what `monk new` writes, the `app/`
layout, every module, `--with`, and the guide.
- Change: two short paragraphs, what `monk new` writes, then what
  `monk add` adds, with the module list left to scaffolding.md.

**G5. Base `SETUP.md`, "Before production"**: "Platform examples:
`docs/guides/deploying.md` in the monk repo". Since 0.26 an app's own
path is `monk add deploy`.
- Change: "To deploy on one host with Docker Compose: `monk add deploy`;
  other platforms: `docs/guides/deploying.md` in the monk repo."

**G6. Base `AGENTS.md` ends on an empty `## Modules`**, and each module's
section is appended as a sibling `##` after it, not under it. In a bare
app the heading has nothing under it.
- Change: one line under it, as `SETUP.md` has: "Each module added with
  `monk add` appends its own section below."

**G7. Small:** scaffolding.md line 106 is one unwrapped line (jobs'
`deliver_later`).

**Round 1 done:** G1–G7 applied. Generator tests: 108 runs, 0
failures, 0 skips; a generated app's `AGENTS.md` checked with mail added.

## Round 2: core guides

Read: routing, forms, boot and shared state, settings, views, logging.
Checked against the code: params merging and the splat, `halt`/`json`
throwing and `render` returning, the default 500, `resources`, the
error classes, `required`/`optional`, `StateRactor#value`/`#update`, the
Model calls in forms.md, `MAX_PARSED_BODY`, the flash cookie, the three
headers, `Log.root`, `kino --check` (Kino 0.7.1). forms.md, settings.md
and logging.md match the code; the findings are in the other three.

**C1. routing.md: "helpers are called bare via `instance_exec`".** Since
0.23.1 each route block becomes a method of `Monk::Context`, not an
`instance_exec`. The one-arg form is described as "useful when you want
to pass a customized `Context` subclass around", which nothing supports.
- Change: "`self` is the request's `Context`, so its methods are called
  bare"; the one-arg form gets the same `Context` as its argument.

**C2. routing.md's `resources` example does what forms.md and AGENTS.md
forbid:** `Order.create(@context.params)`.
- Change: `Order.create(Order.from_form(@context.params[:order]))`,
  with a pointer to forms.md's "From form to row".

**C3. views.md says assets are re-read and unstamped "in development
(`MONK_ENV != "production"`)", and stamped "in production".** The code
(`Assets#production?` is `!Monk.env.development?`) and settings.md's
table say: development only; test, staging and production all build the
manifest and stamp.
- Change: "outside development" / "in development", as settings.md has
  it.

**C4. routing.md's Context list leaves out `flash` and `header(name)`**
(and `csrf_field`, with auth).
- Change: add them, `csrf_field` with a pointer to forms.md.

**C5. routing.md's second paragraph repeats forms.md** (params merging,
`_method`, the cross-site 403) in one dense paragraph.
- Change: keep the matching rule and the 404; one sentence pointing to
  forms.md's "Params", "Verbs other than POST" and "Requests from
  another site".

**C6. Headings: routing.md, boot-and-shared-state.md and views.md each
have two or three `#` titles** ("Context", "Error handling", "Shared
state", "Static assets") under the guide's own. Anchors don't change.
- Change: `##`.

**C7. Small, views.md:** the first paragraph has an unwrapped line;
"Putting nginx or a CDN in front of Monk" → "a proxy (Caddy, in
`monk add deploy`'s stack) or a CDN".

**Round 2 done:** C1–C7 applied; links and anchors checked by script.

## Round 3: data and identity

Read: persistence, migrations, auth, mail. Checked against the code and
the templates: `config/persistence.rb`, postgres's `.env` values, the
Model calls, `bin/migrate`, `config/auth.rb`, `auth_mailer.rb`,
`config/mail.rb`, `JOBS_QUEUES`, `net-smtp`. Pools, dropped connections,
`MAIL_URL`, `Mail.check`, `deliver_later`, the rate limit and the sweep
match the code.

**D1. auth.md's first example hands the login token back in the
response:** `post("/auth/request") { json(token: Monk::Auth.request_login(params[:email])) }`.
Copied as it is, anyone can log in as anyone: ask for a token for their
address, redeem it. The comment says "send this token yourself", but
it's the first code a reader sees.
- Change: the first example is the scaffold's shape: the rate limit,
  `request_login` + `deliver_link` (or `SendLoginLink`), a callback that
  sets the cookie and redirects, `require_user!`.

**D2. The mailer's file is `app/mailers/app_mailer.rb` in auth.md and
mail.md**, and `config/auth.rb`'s `require_relative
"../app/mailers/app_mailer"`; the scaffold has `auth_mailer.rb` (as
scaffolding.md says).
- Change: `auth_mailer.rb` in both guides.

**D3. persistence.md's "Per-environment database names" is from before
`monk add postgres`.** It says to export `DB_NAME` yourself and that
Render/Fly secrets set it. Now `monk add postgres` writes
`DB_NAME=<app>_development` to `.env` and `<app>_test` to `.env.test`
(which the test helper loads), and `monk add deploy` sets `DB_NAME=<app>`.
Its third bullet, Monk's own `MONK_TEST_PG_DATABASE`, is about this
repo, and isn't in `docs/development.md`.
- Change: a short paragraph on what postgres writes, and that `MONK_ENV`
  doesn't pick the database; the `MONK_TEST_PG_DATABASE` line moves to
  `docs/development.md`.

**D4. `:main` in persistence.md, migrations.md and auth.md**, where the
scaffold, `bin/migrate` and the pool's `db:` default are `:primary`.
- Change: `:primary` throughout.

**D5. migrations.md ends on `docs/history/plan-migrations.md` "for the
full design and phase-by-phase plan"**, and doesn't say that `monk add
postgres` writes `bin/migrate` and `bin/setup_db`.
- Change: say what the scaffold gives (`bin/migrate`, `bin/migrate
  rollback`, `bin/setup_db`, migrations from modules timestamped when
  added); drop the history pointer.

**D6. mail.md: "`monk new` sets `JOBS_QUEUES=mailers,push,default`"**:
`monk add jobs` does.

**D7. mail.md, "With `Monk::Auth`": "Require `config/mail.rb` from
`config/load.rb`, not from `config/auth.rb`"**: `config/load.rb` already
loads every config; the point that stays is that `config/auth.rb` doesn't
require it, because `bin/websocket_server` loads `config/auth.rb` alone.
- Change: say that.

**D8. auth.md structure:** its sections are `###` straight under the
title (no `##`); the intro ends on `docs/history/plan-auth.md`'s
"phase-by-phase build"; two unwrapped lines (38–39, 60–61).
- Change: `##`, drop the history pointer, rewrap.

**Round 3 done:** D1–D8 applied. `MONK_TEST_PG_DATABASE` was already in
`docs/development.md`'s services table, so nothing moved there.
`bin/setup_db` migrates but doesn't create the database; migrations.md
says so.

## Round 4: real time

Read: jobs, websocket, live, presence. Checked against the code and the
templates: `bin/jobs`'s and the runtime's defaults, the test helper,
`bin/websocket_server`, `config/websocket.rb`, `config.ru`'s reactor,
`Live.listen!`. presence.md matches; jobs.md has small slips; the
findings are mostly in live.md and websocket.md.

**T1. live.md reads as if the transport were Redis.** The diagram says
`--- Redis --->`; "Running it" says "Both processes must be up, plus
Redis" and "If Redis is down, `Monk::Live.patch` raises
(`Redis::CannotConnectError`)". With the Postgres transport (the pool) a
failed publish is logged, not raised, as the same guide says further
down.
- Change: "the transport" in the diagram and "Running it", with what a
  publish does when it's down for each.

**T2. live.md, "Without Redis": "horizontal scaling (that's still a
separate, unbuilt feature; see
`docs/design/ws-horizontal-scaling-considerations.md`)"**. Several
WebSocket processes are built since 0.22.1 (`WS_PROCESSES`, the
transport between them: websocket.md, "Several processes").
- Change: drop the aside; the transport is needed because there are
  always two processes, and it's also what carries a broadcast between
  several WebSocket processes.

**T3. live.md, "Publishing": "Both processes build the fanout from the
same `config/live.rb`"**: the fanout is built in `config/websocket.rb`;
`config/live.rb` only configures Live on it. The example's
`Monk::Live.listen!` works, but the scaffold calls
`AppWebSocket::REGISTRY.listen!`.
- Change: "from `config/websocket.rb`", and the scaffold's call.

**T4. live.md's pointers to history and to "the monk gem's own repo"**:
`docs/history/reactive-partials.md`, `plan-live.md`,
`plan-live-pg-fanout.md` in the intro and in "Without Redis"; and a note
for apps that copied the client into `public/js/monk_live/` before it
was served from the gem.
- Change: the intro keeps the ADRs (0007–0011) and the design doc
  `live-pg-fanout.md`; the plans and the old-copy note go.

**T5. live.md, "Who may subscribe", says twice that a rule block must be
Ractor-shareable** (the paragraph after the code, and a bullet).
- Change: keep the paragraph, drop the bullet.

**T6. websocket.md's options are one paragraph of about 650 words**
(lines 35–81): `authenticate:`, `allowed_origins:`, `ping_interval:`,
`reverify_interval:`, `max_payload_size:`, `max_handshakes:`,
`handshake_timeout:`, `reuse_port:`, then the proxy, then history.
- Change: a table (option, default, what it does), with the longer
  reasons (why pings, why a minimum of 5 s) as short paragraphs under
  it. The `docs/history/plan-websocket.md` pointer goes; "the proxy" points
  to `monk add deploy` and `deploying.md`.

**T7. jobs.md, small:**
- "`JOBS_QUEUES` ... default `default`": the scaffolded `bin/jobs`
  defaults to `mailers,push,default` (and `monk add jobs` sets
  `JOBS_WORKERS=2` in `.env`).
- "`# a route, in app/app.rb`": routes go in `app/routes/`.
- "`# test/test_helper.rb (as monk new's SETUP.md writes it)`": `monk
  new` writes the test helper itself.
- "What's not here" points to two plans in `docs/history/`; the list
  stands without them.

**Round 4 done:** T1–T7 applied. In websocket.md's table, `allowed_origins:`
unset means no `Origin` check at all (`Server#authenticate!`), so the
Default column says so.

## Round 5: files and devices

Read: storage, pwa, push. Checked against the code and the templates:
the key rules, the API table, `Sniff`, `Storage.check`, the file
backend's paths, `monk push keys`, `push.js` served from the gem, the
recurring sweeps. All three match the code and are written for a newcomer
already (they're the most recent); only small things.

**F1. push.md's list of what `monk add push` writes ends with "in
`config/recurring.rb` (jobs), `Monk::Push::Sweep` every night"**: push
writes nothing there; jobs' `config/recurring.rb` already has the line,
guarded by `defined?(Monk::Push::Sweep)`, as for auth's sweep.
- Change: say that, after the list.

**F2. ADRs as code paths, not links**, in storage.md
(`docs/adr/0018-…`) and mail.md (`docs/adr/0012-…`), where jobs.md and
auth.md link theirs.
- Change: links.

**F3. Small:** storage.md line 243, one unwrapped line (the `415`).

**Round 5 done:** F1–F3 applied; the two opening paragraphs with the new
ADR links rewrapped.

## Round 6: deploying and upgrading

Read: deploying, deploy-hetzner, upgrading, development.md. Checked
against the templates and the code: the base `Dockerfile` (same as the one
shown), `--with`, the Compose files (`stop_grace_period: 35s` on `web` and
`jobs`), `WS_PROCESSES`, presence's keepalives (25 s, then 5 s),
`bin/jobs`' 25 s shutdown and 2-minute timeout, `persistence.rb`'s five
`DB_*` vars, the 0.27 CHANGELOG against upgrading's 0.27 section, and the
repo's `bin/server` (the demo answers 200 in ractor mode). deploy-hetzner
matches the code throughout; deploying.md carries the most history.

**P1. deploying.md section 3 still points to the WebSocket plan, and
says the proxy config isn't generated**: `docs/history/plan-websocket.md`
"Decision 1" and "Decision 8" (lines 239, 247, 299), "Documented here, not
generated by `monk new`". `monk add deploy` now writes the Caddyfile.
- Change: say the rule without the plan (own port; `/ws` routed by path
  on the same host, so the session cookie reaches the handshake; TLS at
  the proxy), that `monk add deploy` writes it for Compose (section 4),
  and that the snippets are for other setups. Link the design doc's
  "Identity crosses the process boundary" instead of naming it as a path.

**P2. deploying.md's opening is written as history**: "Both cases below"
(there are four sections), "needs copying by hand any more", "they're
shown there because...". The map of sections is at line 122, after the
module table.
- Change: open with what the page covers (the module table, then Render,
  Fly.io, the WebSocket process, a single VPS) and that `monk new` writes
  the `Dockerfile`; drop line 122's paragraph.

**P3. Render's "Caveat" is about this repo's own root `Dockerfile`**,
which an app never sees; the Fly section already says the scaffold writes
one.
- Change: drop it.

**P4. Fly multi-process bullet: "run `bin/websocket_server` and `kino`"**.
- Change: `bin/server`.

**P5. "Open question" at the end of deploying.md** (support
`DATABASE_URL` in the scaffold): a design question in a user guide. The
Fly section already gives the two ways around it.
- Change: drop it from the guide; one line under the roadmap's "To
  evaluate".

**P6. deploying.md, jobs: "(`stop_grace_period`, below)"**: nothing
below says it.
- Change: "the Compose file `monk add deploy` writes gives `web` and
  `jobs` 35 s (`stop_grace_period`)".

**P7. Small, deploying.md:** the 9292/9293 sentence ("not 9293 ...
running both on 9293 would collide them") says one thing in a roundabout
way: 9292 is `bin/server`'s default, the WebSocket process's is 9293.
Unwrapped lines 5, 95, 239, 299.

**P8. deploy-hetzner.md cites guides as paths, not links**:
`docs/guides/scaffolding.md` (line 18, where the stack is described in
deploying.md section 4), `mail.md` (54), `presence.md` (204),
`websocket.md` (350).
- Change: links; line 18 to deploying.md section 4.

**P9. upgrading.md 0.27 has no Gemfile line**, where every other release
starts with one.
- Change: `gem "monkrb", "~> 0.27", require: "monk"`, as the others
  (it's R3's README change, here).

**P10. The repo's `bin/server` comment says ractor mode 500s "until Phase
4 lands"**: it serves 200 today. development.md is right; the comment
isn't.
- Change: drop the comment. Also rewrap development.md's two long lines
  (4, 56).

**Round 6 done:** P1–P10 applied. The `DATABASE_URL` question is now a
line under the roadmap's "To evaluate".
