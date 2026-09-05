# Monk Settings & MONK_ENV — implementation plan

Companion doc: `docs/adr/0006-settings-alongside-persistence-and-auth-config.md`
(why `Settings` is a new facility rather than a retrofit of `Persistence`/
`Auth`'s own config). Glossary: `CONTEXT.md` — **Settings**, **MONK_ENV**.

Like `PLAN-AUTH.md`, this develops in small, gradual, red → green cycles.
Each numbered step is one vertical slice: one failing test against its
seam, then the minimum code to pass it.

**Implemented 2026-09-05, all 8 phases**, one commit per phase on
`claude/settings-config-design`. Phase 8's proof lives in the sibling
`../monk-consumer-test` repo (its own commit there), not in this one.

## Decisions locked in before Phase 1

Each of these came out of a grilling session and is a plan assumption.
Reversing one invalidates the phases that rest on it, so they're stated
up front rather than discovered mid-implementation.

1. **`MONK_ENV` has four canonical values**: `development` (default when
   unset), `test`, `staging`, `production`. Nothing else is valid.
2. **The behavioral axis existing code checks is "not `development`,"
   not "`production` only."** `test`, `staging`, and `production` all
   get quiet request logging and manifest-based (not disk-read) asset
   serving; only `development` is verbose/dev-mode.
3. **`base.rb`'s `log_request` moves to the boot-frozen pattern
   `assets.rb` already uses** — `ENV["MONK_ENV"]` is main-Ractor state
   (`docs/persistence-ractor-connections.md`), so a per-request read
   inside a worker Ractor is the same class of bug ADR 0003 exists to
   catch, just not yet caught.
4. **`test/test_helper.rb`'s forced default becomes `MONK_ENV=test`**,
   not `production`. Behavior for the suite is unchanged (assumption 2
   already puts `test` on the quiet side); it stops the suite from
   lying about what it is.
5. **`Settings` subsumes `MONK_ENV`** — `MONK_ENV` is just the
   `:monk_env` key inside `Settings`, with a fixed value set and a
   `development` default, exposed through its own reader (`Monk.env`)
   because it's read constantly.
6. **`Settings` is a new, separate facility — it does not replace
   `Persistence.register` or `Auth.configure`.** See ADR 0006.
7. **Declared via a single `configure` block**, not one method call per
   key: `Monk::Settings.configure { required :x; optional :y, default:
   "z" }`. Mirrors `Auth.configure`'s "several related declarations, one
   block" shape.
8. **Flat keys, no namespacing. String values only, no type coercion.**
   Both are deliberate v1 scope cuts, not oversights — see "Explicitly
   out of scope" below.
9. **Required keys fail fast at `Boot`** (ADR 0003's posture), not at
   `configure` time — `config/settings.rb` runs very early (every entry
   point requires it, including scripts that never call `.freeze!`), so
   validation is tied to the moment an app actually boots to serve
   requests, not to the moment its config file merely loads.
10. **Reading an undeclared key raises**, never returns `nil` — a typo'd
    key becomes a loud error at the read site instead of a silent `nil`
    surfacing confusingly somewhere else.
11. **Read two ways**: `Monk::Settings[:key]` (class-level, boot-time/
    global code) and `Context#settings` (per-request, mirroring
    `Context#params`/`#env`).
12. **`monk` the gem never depends on `dotenv`.** Adoption is a
    scaffold/docs concern only — consistent with `docs/deploying.md`,
    where hosting platforms inject env vars directly and dotenv is
    never mentioned.
13. **A new `config/settings.rb` ships in the *base* scaffold skeleton**
    (always generated, not gated behind `--postgres`), loading dotenv
    first and then declaring `Settings`. `config.ru`, `bin/console`,
    `bin/setup_db`, `bin/migrate`, and `bin/server` all `require_relative`
    it — one shared place instead of five independent wirings.

## Seams

- **Seam A — `Monk::Settings` core, no `Boot` involved**: `configure`,
  `required`/`optional`, `[]`, the undeclared-key raise. Pure Ruby, no
  Rack/HTTP, testable without a running app.
- **Seam B — `Boot` integration**: required-key fail-fast validation and
  `Ractor.make_shareable` on the frozen values, wired through the
  existing `Monk.freeze_hooks` mechanism (`Base#freeze!`), the same seam
  `Assets` and (per `PLAN-AUTH.md` Phase 5) `Auth` use.
- **Seam C — `Monk.env`**: built on `Settings` (the `:monk_env` key), the
  four-value set, the `development` default, and the predicate methods.
- **Seam D — existing consumers migrate**: `base.rb#log_request` and
  `assets.rb`'s `@production` both move from raw `ENV["MONK_ENV"] ==
  "production"` checks to `Monk.env`-based ones; `test_helper.rb`'s
  default flips to `"test"`.
- **Seam E — `Context#settings`**: per-request read access, exercised as
  observable HTTP behavior the way `PLAN.md` Seam A tests routes.
- **Seam F — scaffold**: `config/settings.rb` in the base skeleton,
  `require_relative`'d by every generated entry point.
- **Seam G — real Ractor integration**: `Settings`/`Monk.env` read
  correctly from a real worker Ractor after `Boot` — the recurring
  hazard this codebase keeps re-discovering
  (`docs/persistence-ractor-connections.md`), so it needs its own proof
  here rather than an assumption carried over from Assets/Persistence.
- **Seam H — `monk-consumer-test` end-to-end proof**: the gem consumed
  from outside the repo, a generated app reading its own `Settings` and
  `Monk.env` under a real `kino` pool.

## Phase 1 — `Settings` core (Seam A)

1. `Monk::Settings.configure(&block)` runs the block against a small DSL
   exposing `required(key)` and `optional(key, default:)`. Both accept a
   Symbol. Declaring the same key twice (whether both `required`, both
   `optional`, or one of each) raises immediately — a copy-paste mistake
   caught at declare time, not silently overwritten.
2. `Monk::Settings[:key]` reads a declared key's value from `ENV`
   (String, or the `optional` default if `ENV` doesn't have it) without
   requiring `Boot` to have run — `config/settings.rb` and boot-time code
   in `config.ru` need to read values before `.freeze!` fires.
3. `Monk::Settings[:undeclared_key]` raises a precise error naming the
   key, whether or not `Boot` has run.
4. **Test-only** `Monk::Settings.reset!` clears all declared keys, so
   `test_helper.rb` can isolate specs the way `Assets.reset!`/
   `Views.reset!` already do.

## Phase 2 — `Boot` integration (Seam B)

5. `Base#freeze!` calls a `Settings.freeze_registry!` hook (added to
   `Monk.freeze_hooks`, mirroring `Assets`): every declared `required`
   key is checked present in `ENV` and a missing one raises a precise
   error naming it (ADR 0003's fail-fast spirit, and the same shape as
   `PLAN-AUTH.md` step 5's `Auth.configure` validation).
6. The frozen value hash is `Ractor.make_shareable`'d at that point —
   assert a real worker Ractor can read a previously-declared key after
   `Boot` without `Ractor::IsolationError` (this phase's version of the
   bug `docs/persistence-ractor-connections.md` keeps naming).
7. Calling `Monk::Settings.configure` again after `Boot` raises — the
   registry is closed the same moment routes and views are.

## Phase 3 — `Monk.env` (Seam C)

8. `Monk.env` is built by having `config/settings.rb`'s generated
   template (Phase 6) — and this repo's own boot path — declare
   `required :monk_env` or, more precisely, `Monk::Settings` special-cases
   `:monk_env` internally: always implicitly declared (an app never has
   to `required :monk_env` itself), value validated against the fixed
   four-value set at the same fail-fast point as any other required key,
   default `"development"` when `ENV["MONK_ENV"]` is unset.
9. `Monk.env` returns an object (or the bare String, with predicates
   defined on the small set of allowed values) responding to
   `.development?`, `.test?`, `.staging?`, `.production?` — exactly one
   is `true`.
10. An invalid value (`MONK_ENV=prod`, a typo) raises at `Boot` naming
    the offending value and the allowed set — not a silent fall-through
    to "not production."

## Phase 4 — Existing consumers migrate (Seam D)

11. `assets.rb`'s `freeze_registry!` sets `@production` from
    `!Monk.env.development?` instead of `ENV["MONK_ENV"] ==
    "production"` — behavior is unchanged for `production`, newly
    correct for `staging`/`test` (previously indistinguishable from
    `development` by this check).
12. `base.rb`'s `log_request` reads `Monk.env` once at `Boot` (stored in
    a class ivar alongside `routes`/`error_handlers`) instead of
    `ENV["MONK_ENV"]` per request — closes the inconsistency
    `PLAN-AUTH.md` step 20 flagged, and makes `test/test_helper.rb`'s
    existing comment ("Monk reads MONK_ENV once, at boot, never per
    request") true for the first time.
13. `test/test_helper.rb` line 2 becomes `ENV["MONK_ENV"] ||= "test"`.
    Every existing test that asserts dev-mode behavior via
    `with_monk_env("development") { ... }` still passes unchanged.
14. Real-Ractor regression: assert `log_request`'s suppression under
    `MONK_ENV=production` still holds under a real `kino`-style worker
    pool — this is the exact scenario `PLAN-AUTH.md` step 20 said could
    be silently broken and explicitly punted on.

## Phase 5 — `Context#settings` (Seam E)

15. `Context#settings` returns the same frozen values `Monk::Settings[]`
    would, from inside a route handler — observable as HTTP behavior
    (a route reading `settings[:some_key]` and echoing it in the
    response body).
16. Reading an undeclared key through `Context#settings` raises the same
    way `Monk::Settings[]` does — one error path, not two.

## Phase 6 — Scaffold (Seam F)

17. `lib/monk/templates/base/config/settings.rb` — a new scaffold
    template, generated regardless of `--postgres` — contains, in order:
    an optional `require "dotenv/load"` guarded so a missing `.env` file
    (or the gem itself not being in the generated `Gemfile`) doesn't
    raise, then a `Monk::Settings.configure` block the scaffold leaves
    empty (or with one commented example) for the app to fill in.
18. `lib/monk/templates/base/Gemfile` gains a commented-out `gem
    "dotenv"` line — present but inactive, so adopting it is uncommenting
    one line, not hunting for where it goes.
19. `config.ru`'s template gains `require_relative "config/settings"` as
    its first line (before the app class body). Same
    `require_relative "../config/settings"` line is added to
    `bin/console`, `bin/setup_db`, `bin/migrate`, and `bin/server`'s
    generated versions (the `--postgres` variants, plus `bin/server`
    from the base skeleton).
20. `monk new`'s own test (`test/scaffold_test.rb`) asserts
    `config/settings.rb` exists in a freshly generated app regardless of
    `--postgres`, and that the generated `config.ru`/`bin/*` scripts
    reference it.

## Phase 7 — Real Ractor integration (Seam G)

21. A `DemoApp`-style app (mirroring `config.ru`'s existing demo)
    declares a `Settings` key, boots, and is served under a real worker
    Ractor pool; concurrent requests each read the same frozen value
    correctly — the analogue of `PLAN.md` Seam D and `PLAN-AUTH.md`
    Phase 7.
22. Same proof for `Monk.env`'s predicates specifically, since Phase 4's
    migration is exactly the code path `PLAN-AUTH.md` step 20 worried
    about.

## Phase 8 — `monk-consumer-test` end-to-end proof (Seam H)

23. A generated app (via `monk new`, no flags) has a working
    `config/settings.rb`, declares one custom setting alongside
    `MONK_ENV`, and serves a route reading both under a real `kino`
    pool — the same shape as `PLAN-AUTH.md` Phase 10 and
    `PLAN-WEBSOCKET.md` Phase 8.

## Open questions

- **Non-`Boot` entry points and required-key validation — still open.**
  `bin/console`, `bin/setup_db`, and `bin/migrate` `require_relative
  config/settings.rb` (Phase 6) but never call `App.freeze!` — so Phase
  2's fail-fast validation (tied to `Boot`) never runs for those
  scripts. A console session can read a `Settings` value that would
  have failed validation had the web app actually booted. Left
  unresolved as shipped: those scripts aren't serving requests, so an
  unvalidated-but-present config was judged acceptable for now, but
  `Settings` has no explicit `validate!` entry point for them to opt
  into if that judgment changes.
- ~~Error class naming~~ — resolved in Phase 1/2/3: five classes, one
  per failure mode (`UnknownSettingError`, `DuplicateSettingError`,
  `MissingSettingError`, `SettingsFrozenError`, `InvalidMonkEnvError`),
  matching the existing one-class-per-failure-mode convention
  (`MissingAuthConfigError`, `AuthNotConfiguredError`, etc.).

## Explicitly out of scope for this plan

- **Type coercion** (Integer/Boolean settings) — string-only for v1; see
  `CONTEXT.md`'s **Settings** entry. Revisit only if a real need shows
  up.
- **Namespaced/nested keys** — flat only for v1.
- **Retrofitting `Persistence.register`/`Auth.configure`** to route
  through `Settings` — see ADR 0006. Not planned, not a deferred phase.
