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
