# Passwordless authentication & sessions

Status: design proposal, 2026-08-31 — no code yet. Implementation plan:
`PLAN-AUTH.md`. Working branch:
`claude/passwordless-auth-session-6dfx9u`. No ADR yet; the two decisions
most likely to deserve one are called out under "Open questions."

Sessions/cookies were a deliberate v1 scope cut (`README.md`, `PLAN.md`)
and "Authentication and user sessions" is a listed V2 candidate
(`NOTES-V2.md`). This doc proposes the shape; nothing here is
implemented.

## Why passwordless fits Monk specifically

The framing that matters for this project isn't UX, it's state. A
server-side session object (Rails-style `session[...]`, a session store
in memory) is exactly the cross-request mutable state Monk's whole
design refuses to hand out casually — it would have to live in a
`StateRactor`, and then it's per-process, lost on restart, and a
serialization point on the hot path.

A TTL'd opaque token has no such state. Verifying a request is:

1. hash the presented token (`SHA-256`),
2. one indexed equality lookup by that hash,
3. compare `expires_at` against `Time.now`.

Pure computation plus a per-Ractor database connection Monk already
knows how to manage (`docs/persistence-ractor-connections.md`). Nothing
shared, nothing mutable, nothing that needs `Ractor.make_shareable`
beyond a frozen config Hash. That's why this is the right auth design
for Monk and not merely a fashionable one.

## Prerequisites: four gaps in v1 that auth trips over

These are the actual work; the token logic is the easy half. Each is
already known (`NOTES-V2.md` "Known limitations") except the first.

1. **`Context` can't see the request.** `lib/monk/base.rb:62` builds
   `Context.new(params)` and discards `env` entirely. A route can read
   path segments and nothing else — no `Authorization`, no `Cookie`, no
   query string. Every possible auth scheme needs this, so it's the one
   unavoidable prerequisite.
2. **No response headers.** `lib/monk/context.rb:14` (`halt`) and `:18`
   (`json`) hardcode `{}` / a lone content-type, and
   `lib/monk/base.rb:65` hardcodes `[200, {}, ...]`. Without a mutable
   `ctx.headers` merged into the response there is no `Set-Cookie`, no
   `WWW-Authenticate`, and no `Location` for a magic-link redirect.
3. **No query-string or body parsing.** `params` comes only from path
   segments. A magic link naturally arrives as `?token=...`; a login
   request arrives as a JSON body.
4. **No middleware / `use`.** Guarding is per-route by necessity —
   either an explicit `require_user!` call inside each protected block,
   or a `before` filter list sealed at boot alongside the route table.

### Minimal viable slice

Only #1 is unavoidable. A first slice that puts the login token in a
**path segment** (`get("/auth/callback/:token")`) and answers in JSON,
handing the session token back in the response body for the client to
present as `Authorization: Bearer`, defers #2, #3 and #4 completely.
That's the slice `PLAN-AUTH.md` Phases 1–4 build.

The cost of that shortcut is logging: `lib/monk/base.rb:81` writes
`PATH_INFO` to stdout, so a token in the path lands in the log line. It
is suppressed when `MONK_ENV=production` (`base.rb:79`), so the
exposure is dev/staging logs only — but it's a reason to redact
`/auth/callback/...` in `log_request`, and a reason the eventual
non-slice design should prefer a body or query parameter over a path
segment. (`PATH_INFO` excludes the query string, so `?token=` is not
logged today.)

## Two tokens, not one

Conflating the magic link with the session is the standard mistake in
this design. They have opposite lifetimes and opposite reuse rules:

| | login token (magic link) | session token |
|---|---|---|
| TTL | 10–15 minutes | 14 days |
| uses | exactly one, then dead | many |
| subject | an email, no session yet | an authenticated subject |
| revocation | consumed on redemption | explicit logout / revoke-all |
| delivered by | email, out of band | response body or cookie |

Rules that apply to both:

- Generated with `SecureRandom.urlsafe_base64(32)` — 256 bits of
  entropy from a CSPRNG. Never a hash of predictable inputs, never a
  counter, never `rand`.
- **Only `SHA-256(token)` is stored.** A database leak then yields
  hashes, not live sessions. Lookup stays a single indexed equality
  query, which is all `Monk::Persistence::Pg::Model#where` can express
  anyway. A plain digest (not bcrypt/argon2) is correct here precisely
  because the input is high-entropy random, not a human password —
  there is nothing to brute-force offline.
- The raw token exists in exactly two places: the response/email that
  delivers it, and the client. It is never logged and never echoed back
  by another endpoint.

### Schema

```sql
-- db/migrate/<version>_create_login_tokens.up.sql
CREATE TABLE login_tokens (
  id         BIGSERIAL PRIMARY KEY,
  email      TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ NOT NULL,
  used_at    TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_login_tokens_expires_at ON login_tokens (expires_at);

-- db/migrate/<version>_create_sessions.up.sql
CREATE TABLE sessions (
  id         BIGSERIAL PRIMARY KEY,
  subject    TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_sessions_subject ON sessions (subject);
CREATE INDEX idx_sessions_expires_at ON sessions (expires_at);
```

Versioned `.up.sql`/`.down.sql` pairs, per `PLAN-MIGRATIONS.md` — no
DSL, sent to Postgres verbatim.

**Monk should not own a `users` table.** `sessions.subject` is an opaque
String the app assigns meaning to (an email, a UUID, a tenant-scoped
key). Monk owns tokens; the app owns accounts. The moment the framework
ships a user schema it has taken the first step toward the
ActiveRecord-shaped stack `PLAN-PERSISTENCE.md` explicitly refuses, and
it inherits every downstream question (profile fields, soft delete,
uniqueness, email change) with it.

## Storage: three options

**A — DB-backed opaque tokens (recommended).** Both tables above,
reached through `Monk::Persistence::Pg::Model`. Per-Ractor connections
already work; revocation and single-use are expressible; the token
carries no information. Cost: two schema objects and a sweeper. See the
next section for where the current `Model` API falls short.

**B — Stateless HMAC token, no database.** `base64(subject|expires_at)`
plus an HMAC over it, verified with a frozen secret. Trivially
Ractor-safe (a frozen String), zero storage, zero query on the hot
path. But it cannot be revoked and cannot be made single-use, so it is
**wrong for the magic link** — the link stays replayable for its entire
TTL, which is the one property a magic link must not have. It is
defensible for the *session* token alone if TTL-only invalidation is
acceptable; understand that logout then becomes a client-side
convention, not a server-side fact.

**C — `StateRactor` as the token store.** Appealing because it is
Monk's sanctioned shared-state primitive, and it would work correctly
under a single process's Ractor pool. Rejected as the source of truth:
state is per-process and lost on restart, so it breaks as soon as more
than one process serves the app, and every session dies on deploy.

`StateRactor` does have a real job here, though: **rate limiting
`POST /auth/request`**. Per-process counters are acceptable for that
(the limit is approximate by nature), it needs no durability, and
without it the endpoint is an email-bombing vector aimed at third
parties. This is a good fit for the primitive as documented in
`CONTEXT.md` — the counter update block must be predefined where `self`
is shareable, not written inline in the route.

## Where today's `Pg::Model` doesn't reach

Three queries this design needs are outside the current API. `where` is
equality + `AND` only, deliberately (`PLAN-PERSISTENCE.md` Phase 3, step
9), and `update` takes an `id` with no additional guard.

1. **TTL comparison** — `expires_at > now()` is not expressible. No API
   change needed: fetch the single row by `token_hash`, compare
   `Time.now` in Ruby. One row, already indexed.
2. **Single-use redemption** — this is the one that matters. Correct
   redemption is one atomic statement:

   ```sql
   UPDATE login_tokens SET used_at = now()
   WHERE token_hash = $1 AND used_at IS NULL
   RETURNING *
   ```

   `Model.update(id, data)` cannot express the `AND used_at IS NULL`
   guard, so a read-then-update leaves a genuine race: two concurrent
   redemptions of the same link both observe `used_at IS NULL` and both
   mint a session. Under a Ractor worker pool that is not theoretical —
   mail clients and link scanners prefetch, and a double-clicked link
   is two requests. **Proposed fix:** add
   `Model.claim(conditions, data)` — a conditional `UPDATE ...
   RETURNING *` that returns the row or `nil`. One method, backend-
   agnostic, still equality-only, and it closes the only correctness
   hole in this design. `Pg.checkout(db_name) { |conn| ... }` with raw
   SQL is the escape hatch if `Model` shouldn't grow.
3. **Sweeping expired rows** — `DELETE WHERE expires_at < now()` is not
   expressible either. Don't grow `Model` for it: a `bin/` task issuing
   raw SQL through `Pg.checkout`, run on a schedule, is the honest
   answer. Expired rows are already rejected at verification time, so
   the sweep is hygiene, not correctness.

## Ractor-safety notes specific to this feature

- **Config must be frozen at boot, and the frozen thing is the value.**
  `Monk::Auth.configure(secret:, login_ttl:, session_ttl:)` storing a
  Hash in a module ivar is unreadable from a worker Ractor unless that
  Hash itself is made shareable — freezing the module does nothing,
  since Modules and Classes are always `Ractor.shareable?` regardless
  of their ivars. This is the exact bug documented twice already in
  `docs/persistence-ractor-connections.md` ("Phase 4 finding" for
  `Model` config, "Phase 5 finding" for `Persistence`'s own
  `@configs`). Do not rediscover it a third time: register a freeze
  hook the way `Persistence::Registry.extended` does, so `Base#freeze!`
  seals `Monk::Auth` without needing to know its name.
- **Read the secret once, at boot, on the main Ractor.** Not for
  isolation reasons: `ENV["X"]` was verified readable from inside a
  non-main Ractor (Ruby 3.3.6 — returned the correct value, full
  environment visible; unverified on the 4.0 the gemspec requires). The
  reasons are ordinary ones — fail fast and loudly if the secret is
  missing (ADR 0003's spirit), keep it out of the per-request path, and
  hold it as one frozen String the whole pool can read.
- **Email delivery stays outside the framework.** A mailer object
  captured in a route closure fails `freeze!` with
  `UnshareableRouteError`, and rightly so. `Monk::Auth.request_login`
  should *return* the raw token and let the app deliver it; Monk taking
  on SMTP would be a much larger scope claim than auth.
- **Helpers, not state.** `require_user!` / `current_subject` live in a
  `Monk::Auth::Helpers` module mixed into the `Context` class. A
  `Context` is per-request and never crosses Ractors (`CONTEXT.md`), so
  helpers holding request-scoped memoization are exempt from the app's
  shareability constraints.

## Proposed API

```ruby
require "monk/auth"

Monk::Auth.configure(
  db_name:     :primary,
  secret:      ENV.fetch("MONK_AUTH_SECRET"),   # boot, main Ractor
  login_ttl:   600,       # 10 minutes
  session_ttl: 1_209_600, # 14 days
)

class App < Monk::Base
  post("/auth/request") do
    token = Monk::Auth.request_login(params[:email])
    Mailer.magic_link(params[:email], token)  # app's job, not Monk's
    json(ok: true)                            # never echo the token
  end

  get("/auth/callback/:token") do
    session = Monk::Auth.redeem(params[:token])
    halt 401, "invalid or expired link" unless session
    json(token: session[:token], expires_at: session[:expires_at])
  end

  get("/me") do
    subject = require_user!   # reads Bearer from ctx.env, halts 401
    json(subject: subject)
  end

  delete("/auth/session") do
    Monk::Auth.revoke(require_token!)
    json(ok: true)
  end
end
```

`Monk::Auth` is opt-in the way persistence backends are — `require
"monk"` alone must not load it, since it depends on a persistence
backend the app may not use.

## Security decisions worth stating explicitly

- **No user enumeration.** `POST /auth/request` returns the same
  `{ok: true}` whether or not the email is known. Whether an unknown
  email creates a subject on first successful redemption is the app's
  policy, not Monk's.
- **Rate limit both endpoints.** `/auth/request` per email and per IP
  (email-bomb vector); `/auth/callback` per IP (guessing, though 256
  bits makes that theatre).
- **Single-use is a correctness requirement, not a nicety** — see the
  atomic-claim gap above.
- **Token comparison is by hash lookup**, so no secret-dependent string
  comparison happens in Ruby and timing is a non-issue. If a code path
  ever does compare tokens directly, use
  `OpenSSL.secure_compare`.
- **Referer leakage.** A magic link that lands on an HTML page carrying
  third-party assets can leak the token via `Referer`. Redeem-then-
  redirect (302 to a token-free URL) is the fix — and it needs
  prerequisite #2, which is part of why the first slice answers in JSON
  instead.
- **Cookies, when they arrive, need `HttpOnly; Secure; SameSite=Lax`**
  and bring CSRF into scope for state-changing routes. `Bearer` avoids
  that entirely, which is the second reason the first slice is
  API-first.

## Open questions

1. **Bearer or cookie first?** Recommendation: Bearer. It skips
   prerequisites #2–#4 and defers CSRF. Cookies are the better browser
   answer eventually.
2. **Rolling or absolute session expiry?** Recommendation: absolute.
   Rolling means a database write on every authenticated request, which
   is a real cost under a Ractor pool and turns a read-only hot path
   into a write one. Revisit with a "refresh if older than N" variant
   if 14 days proves too short.
3. **`Model.claim` or a raw-SQL escape hatch for atomic redemption?**
   Recommendation: `Model.claim` — this is the decision most likely to
   want an ADR, since it's the first extension of a deliberately
   minimal query surface.
4. **Does `Monk::Auth` own the `login_tokens` schema, or ship it as a
   generator?** Leaning: ship migrations through `Monk::Scaffold`
   (`PLAN-INIT.md`) as an opt-in template, so the app owns its schema
   and can add columns.

## Explicitly out of scope

No passwords, ever (that's the point). No OAuth/OIDC/SAML, no WebAuthn/
passkeys, no TOTP or second factors, no "remember this device", no
account/user schema, no email delivery or templating, no
authorization/roles/permissions (this doc is authentication only), no
CSRF machinery until cookies exist, no session listing/"log out
everywhere" UI, no JWT (option B is a plain HMAC token, not a JWT — no
`alg` field, no algorithm negotiation, no library).
