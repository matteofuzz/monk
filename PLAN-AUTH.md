# Monk passwordless auth & sessions — implementation plan

Branch: `claude/passwordless-auth-session-6dfx9u`. Companion doc:
`docs/auth-sessions.md` (design rationale, storage options considered,
security decisions, open questions).

Like `PLAN.md`, this develops in small, gradual, red → green cycles.
Each numbered step is one vertical slice: one failing test against its
seam, then the minimum code to pass it. Refactoring is a separate pass
per item, not folded into the loop itself.

Nothing here is implemented yet. Phases 1 and 5 are prerequisites in the
framework itself, not auth code — auth is simply the first feature that
can't be built without them.

## Decisions locked in before Phase 1

Each of these is a recommendation from `docs/auth-sessions.md` promoted
to a plan assumption. Reversing one invalidates the phases that rest on
it, so they're stated up front rather than discovered mid-implementation.

1. **Two separate token kinds**, two tables: single-use `login_tokens`
   (~10 min TTL) and multi-use `sessions` (~14 day TTL). Not one table
   with a `kind` column — the reuse rules differ, and merging them
   invites redeeming a session as a login token.
2. **Opaque random tokens, stored as `SHA-256` digests.**
   `SecureRandom.urlsafe_base64(32)`; the raw token is never persisted
   and never logged. Rejected: HMAC-signed stateless tokens as the
   primary design (no revocation, no single-use — see the companion
   doc's option B).
3. **Postgres is the store**, through `Monk::Persistence::Pg::Model`.
   Rejected: `StateRactor` as the source of truth (per-process, lost on
   restart). `StateRactor` is still used, for rate limiting only
   (Phase 8).
4. **Bearer token first, cookies later.** The first working slice is
   API-shaped: token in a path segment on the way in, session token in
   a JSON body on the way out, `Authorization: Bearer` thereafter. This
   defers response headers, query/body parsing, and CSRF entirely.
   Cookies are Phase 9, and optional.
5. **Absolute session expiry, not rolling.** Rolling expiry means a
   write on every authenticated request — a read-only hot path turned
   into a write one, under a Ractor worker pool.
6. **Monk owns tokens; the app owns users.** `sessions.subject` is an
   opaque String. No `users` table ships with the framework.
7. **`Monk::Auth` is opt-in**, like persistence backends: `require
   "monk/auth"` explicitly. `require "monk"` must not load it, since it
   depends on a backend the app may not use.
8. **Email delivery is not Monk's job.** `request_login` returns the raw
   token; the app sends it.

## Seams

- **Seam A (extended) — `App.call(env)`**: the request/response
  plumbing auth needs (`Context#env`, response headers), tested as
  observable HTTP behavior exactly as `PLAN.md` Seam A does.
- **Seam B (extended) — `.freeze!` / boot**: `Monk::Auth`'s config must
  be made `Ractor.shareable?` at boot, the same way `Model` config and
  `Persistence`'s registry already are.
- **Seam N — `Monk::Auth`'s own public API**: issue / redeem / verify /
  revoke, tested directly against its own interface with a live
  Postgres, not through HTTP (mirrors Seam E/F).
- **Seam O — route-level guarding through `App.call(env)`**: the
  `require_user!` helper and the 401 path, observable as HTTP.
- **Seam P — real concurrent Ractor integration**: multiple real
  Ractors verifying sessions and racing to redeem one login token — the
  only place the single-use guarantee is actually proven (the analogue
  of `PLAN.md` Seam D and `PLAN-PERSISTENCE.md` Seam G).
- **Seam Q — `monk-consumer-test` end-to-end**: the gem consumed from
  outside the repo, serving a real magic-link round trip under `kino`.

## Phase 1 — `Context` sees the request (Seam A extended)

The unavoidable prerequisite: `lib/monk/base.rb:62` currently builds
`Context.new(params)` and discards `env`.

1. `Context#env` returns the Rack `env` Hash for the request — a route
   block can read `env["HTTP_AUTHORIZATION"]`.
2. `Context#header(name)` reads a request header by its plain name
   (`ctx.header("authorization")`), handling the `HTTP_`-prefixed,
   underscored, upcased Rack form. A missing header returns `nil`.
3. The `404` path (`lib/monk/base.rb:92`) also receives `env` — today it
   hardcodes `Context.new({}, status: 404)`. Fixing this while here also
   removes a limitation already logged in `NOTES-V2.md` ("`error 404`
   handlers can't see route params").
4. `env` is per-request and never crosses a Ractor boundary, so it
   changes nothing about shareability — assert this directly: an app
   with a route reading `ctx.env` still passes `freeze!` and still
   returns correct, independent responses from concurrent real Ractors.

## Phase 2 — Token core, no HTTP (Seam N, part 1)

Runs against the live (Dockerized) Postgres from
`PLAN-PERSISTENCE.md` Phase 0, with the two tables from
`docs/auth-sessions.md` applied as migrations
(`PLAN-MIGRATIONS.md` file conventions).

5. `Monk::Auth.configure(db_name:, secret:, login_ttl:, session_ttl:)`
   stores config and is readable back; a missing required key raises a
   precise error naming it (ADR 0003's fail-fast spirit).
6. `Monk::Auth.request_login("a@b.com")` inserts one `login_tokens` row
   and returns the raw token. Assert the raw token is **not** what's
   stored: the row's `token_hash` equals `SHA-256(raw)` and the raw
   value appears nowhere in the row.
7. Two calls for the same email produce two distinct tokens (no
   dedupe/reuse) — both rows valid until one is redeemed.
8. `Monk::Auth.redeem(raw)` on a fresh token returns a session Hash
   (`:token`, `:subject`, `:expires_at`), inserts one `sessions` row,
   and marks the `login_tokens` row `used_at`.
9. `redeem` returns `nil` for: an unknown token, a malformed/empty
   token, and a token whose `expires_at` is in the past (insert one
   directly with a past `expires_at` — don't sleep).

## Phase 3 — Atomic single-use redemption (Seam N, part 2)

The one correctness hole in the design; see the companion doc's "Where
today's `Pg::Model` doesn't reach."

10. `redeem` on an already-redeemed token returns `nil` and does **not**
    create a second session row.
11. Redemption is a single conditional statement, not read-then-update:
    `Model.claim(conditions, data)` issues `UPDATE ... WHERE <equality
    conditions AND ...> RETURNING *` and returns the updated row or
    `nil`. Test it directly against its own interface first (two
    sequential claims of the same row: first wins, second returns
    `nil`), then build `redeem` on it. The concurrent proof is Phase 7,
    step 21 — a sequential test cannot demonstrate atomicity.
12. `Model.claim` stays equality-only, consistent with `where`
    (`PLAN-PERSISTENCE.md` Phase 3, step 9). The `used_at IS NULL` guard
    is expressed as a `nil` condition value mapping to `IS NULL`, not as
    an operator DSL. If that proves too narrow, the fallback is raw SQL
    through `Pg.checkout` in `Monk::Auth` and no `Model` change at all —
    decide before implementing, not after.

## Phase 4 — Session verification & revocation (Seam N, part 3)

13. `Monk::Auth.verify(raw)` returns the subject for a valid session
    token, `nil` for unknown, expired, or revoked.
14. `Monk::Auth.revoke(raw)` sets `revoked_at`; a subsequent `verify`
    returns `nil`. Revoking an unknown token returns `false` rather
    than raising (mirrors `Model.delete`'s "did it actually happen"
    return).
15. `Monk::Auth.revoke_all(subject)` revokes every live session for a
    subject and returns how many.
16. `Monk::Auth.sweep!` deletes expired `login_tokens` and `sessions`
    rows and returns the counts. Raw SQL through `Pg.checkout` — this
    one deliberately does not grow `Model` (a `<` comparison is real
    query-DSL scope growth for a hygiene task).

## Phase 5 — Boot integration (Seam B extended)

17. `Monk::Auth`'s config is made `Ractor.shareable?` by `Base#freeze!`
    via the existing freeze-hook mechanism (`Monk::Persistence.
    freeze_hooks`, or a generalization of it if auth shouldn't hang off
    a persistence-named list). **Freeze the value, not the module** —
    Modules are always `Ractor.shareable?` regardless of their ivars.
    This is the third instance of the same bug in this codebase; see
    `docs/persistence-ractor-connections.md` "Phase 4 finding" and
    "Phase 5 finding".
18. The failing test for step 17 must run *inside a real Ractor* —
    every one of `PLAN-PERSISTENCE.md` Phases 1–4's tests passed while
    the code was in fact unusable from a worker Ractor, because none of
    them ever left the main one. A main-Ractor-only test here proves
    nothing.
19. A `Monk::Auth` method called before `configure` raises a precise
    error saying so, rather than failing obscurely deep in a query.

## Phase 6 — Guarding a route over HTTP (Seam O)

20. `Monk::Auth::Helpers` is mixed into the `Context` class, providing
    `current_subject` (memoized per request, `nil` when absent) and
    `require_user!` (returns the subject, or `halt 401` — asserted
    through `App.call(env)` as a real 401 response).
    - missing `Authorization` header → 401
    - malformed header (no `Bearer ` prefix, empty token) → 401
    - expired / revoked / unknown token → 401
    - valid token → 200, and the handler sees the right subject
    - `current_subject` on an unguarded route → `nil`, still 200

## Phase 7 — Real Ractor integration (Seam P)

21. **The race-safety proof.** N real Ractors all call
    `Monk::Auth.redeem` with the *same* login token concurrently:
    exactly one returns a session, all others return `nil`, and
    `sessions` contains exactly one new row. This is the step Phase 3
    exists to make possible and the reason `Model.claim` is a
    conditional `UPDATE` rather than a read-then-update — mirrors
    `PLAN.md` step 20 and `PLAN-PERSISTENCE.md` step 16.
22. N real Ractors concurrently verifying N distinct valid session
    tokens all succeed with correct, independent subjects.
23. A full magic-link round trip driven through `App.call(env)` from
    inside a real worker Ractor: request → redeem → authenticated call.

## Phase 8 — Rate limiting `/auth/request` (Seam C extended)

24. A `StateRactor` holding per-email/per-IP counters with a coarse time
    window rejects the N+1th request in a window with `429`. Per-process
    and approximate by design (see the companion doc); durability is
    explicitly not a goal.
25. The counter's `update` block is predefined where `self` is
    shareable, not written inline in the route handler — the
    `CONTEXT.md` rule for `StateRactor`. Assert the app still passes
    `freeze!`, since getting this wrong is exactly what
    `UnshareableBlockError` exists to catch.

## Phase 9 — Cookies, redirects, response headers (Seam A extended)

Deferred by decision 4, and only if a browser-facing flow is actually
wanted. Nothing in Phases 1–8 depends on it.

26. `Context#headers` is a mutable per-request Hash merged into the
    response by `dispatch`, `halt`, and `json` — replacing the
    hardcoded `{}` / lone content-type at `lib/monk/context.rb:14`,
    `:18` and `lib/monk/base.rb:65`. Closes another limitation logged
    in `NOTES-V2.md` ("No custom response headers").
27. `Context#redirect(location, status: 302)` — needed so the callback
    can redeem and then bounce to a token-free URL, which is what keeps
    the token out of the `Referer` header.
28. Query-string parsing into `params`, so `?token=...` works and the
    token leaves the path (`lib/monk/base.rb:81` logs `PATH_INFO`).
29. Session cookie set with `HttpOnly; Secure; SameSite=Lax`, read back
    by `current_subject` when no `Authorization` header is present.
    **CSRF enters scope here** — a cookie-authenticated state-changing
    route needs a token check, which is its own design pass and
    probably its own plan.

## Phase 10 — `monk-consumer-test` end-to-end proof (Seam Q)

30. The consumer app (see `PLAN-PERSISTENCE.md` Phase 6) gains the two
    migrations, `require "monk/auth"`, a `Monk::Auth.configure` in
    `config/persistence.rb`'s sibling `config/auth.rb`, and three
    routes: request, callback, and a guarded `GET /me`.
31. Verified manually against a disposable `postgres:16` container under
    real `kino` (multiple worker Ractors), with real HTTP requests:
    request a link, redeem it, call `/me` with the returned Bearer
    token, revoke, confirm the next `/me` is 401. Documented as a
    verification step, not an automated cycle — mirrors `PLAN.md`
    step 21.

## Explicitly out of scope for this plan

Carried over from the companion doc's scope cuts: no passwords, no
OAuth/OIDC/SAML, no WebAuthn/passkeys, no TOTP or second factors, no
"remember this device", no user/account schema, no email delivery or
templating, no authorization/roles/permissions (authentication only),
no JWT, no session-listing or "log out everywhere" UI, no CSRF
machinery (Phase 9 flags where it would begin), no query-condition DSL
beyond equality + `AND` + `IS NULL`, no scheduled-job runner for
`sweep!` (async jobs are their own `NOTES-V2.md` candidate).
