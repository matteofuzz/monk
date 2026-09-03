# Passwordless authentication & sessions

Status: design finalized across all three transports, 2026-09-01 — no code
yet. Implementation plan: `PLAN-AUTH.md`. Working branch:
`claude/passwordless-auth-session-6dfx9u`. No ADR yet; the decisions most
likely to deserve one are called out under "Open questions."

This revises the 2026-08-31 pass, which deliberately scoped down to a
Bearer-only slice and deferred the browser and WebSocket cases entirely
(old "Open questions" #1). That deferral is resolved here: this doc now
specifies one token model carried three ways — `Authorization: Bearer` for
API/server-to-server callers, an `HttpOnly` cookie for browsers, and a
carrier for `Monk::WebSocket` (`docs/websocket.md`) connections that turns
out to need no new mechanism at all for the browser case. Nothing below
changes the core design ("Two tokens, not one", the schema, the storage
options): it adds the delivery and CSRF layer the original pass punted on.

Sessions/cookies were a deliberate v1 scope cut (`README.md`, `PLAN.md`)
and "Authentication and user sessions" is a listed V2 candidate
(`NOTES-V2.md`). This doc proposes the shape; nothing here is
implemented.

## The three transports, one token model

| Client | Carrier | Why |
|---|---|---|
| API / server-to-server | `Authorization: Bearer <token>` | No browser, no cookie jar, no CSRF exposure — a third party can't forge a header it has no channel to set. |
| Browser (interactive user) | `HttpOnly; Secure; SameSite=Lax` cookie | A cookie the client can't read from JS resists token theft via XSS in a way a Bearer token stashed in `localStorage`/`sessionStorage` (readable by any script on the page) does not. This is the actual reason to prefer cookies for a browser client, not merely "browsers use cookies." |
| `Monk::WebSocket` connection | Whichever of the above the connecting client already has | See "The WebSocket case" below — this needs no third mechanism. |

`current_subject` / `require_user!` (`docs/auth-sessions.md`'s "Proposed
API") check `Authorization` first and fall back to the cookie when absent.
Both remain first-class; nothing here removes Bearer or makes cookies
mandatory. Which one a given app uses is a client-side choice, not a
server-side mode switch.

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
  id           BIGSERIAL PRIMARY KEY,
  email        TEXT NOT NULL,
  token_hash   TEXT NOT NULL UNIQUE,
  redirect_to  TEXT,
  expires_at   TIMESTAMPTZ NOT NULL,
  used_at      TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_login_tokens_expires_at ON login_tokens (expires_at);

-- db/migrate/<version>_create_sessions.up.sql
CREATE TABLE sessions (
  id         BIGSERIAL PRIMARY KEY,
  subject    TEXT NOT NULL,
  prefix     TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_sessions_subject ON sessions (subject);
CREATE INDEX idx_sessions_expires_at ON sessions (expires_at);
```

`prefix` and a nullable `expires_at` are here for the API-key case below;
an ordinary login-derived session populates `prefix` too and gets a
14-day `expires_at` like any other row in this table — one shape, not
two. `login_tokens.redirect_to` is `NULL` for an API/Bearer request and a
same-app path for a browser one — see "The browser case" below for how it
picks the callback's response shape. It is copied verbatim from the
`POST /auth/request` payload, validated against the app's own allowlist at
write time, not at redemption time, so a malicious value never even
reaches the row.

Versioned `.up.sql`/`.down.sql` pairs, per `PLAN-MIGRATIONS.md` — no
DSL, sent to Postgres verbatim.

**Monk should not own a `users` table.** `sessions.subject` is an opaque
String the app assigns meaning to (an email, a UUID, a tenant-scoped
key). Monk owns tokens; the app owns accounts. The moment the framework
ships a user schema it has taken the first step toward the
ActiveRecord-shaped stack `PLAN-PERSISTENCE.md` explicitly refuses, and
it inherits every downstream question (profile fields, soft delete,
uniqueness, email change) with it.

## A third case: server-to-server API keys

Server-to-server callers don't fit either row of the table above — no
email, no interactive redemption, no browser. An API key is a session
token whose issuance path skips the login-token round-trip entirely:
same table, same verification code, same revocation, per the schema
above.

What's different from a browser session:

- **Minted out-of-band.** `Monk::Auth.create_api_key(subject:,
  expires_at: nil)` is called from a CLI task or an app-built admin
  route — never from a public endpoint like `/auth/request`. There's no
  magic link to click, so there's no `login_tokens` row for this path at
  all.
- **`expires_at` is nullable.** A service credential that should live
  until explicitly revoked, not until a clock runs out, needs
  `revoked_at` as its only lifecycle knob. Verification becomes
  `revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())` —
  one extra branch on the same single-row read from the `Model` gap
  section below.
- **`prefix` exists so a human can identify a key without ever seeing it
  again.** The raw token still exists in exactly two places (the
  one-time creation response and the client) — `prefix` is the first
  handful of characters of that raw value, stored in plaintext at mint
  time, so an admin view or a log line can show `mk_9f2a3c1d…` for
  "which key is this" without weakening the "only the hash is stored"
  rule.

What stays identical: the wire format (`Authorization: Bearer <token>`),
the verification code path (`require_user!` / `current_subject`), and
the entropy/hashing rules from "Two tokens, not one" above. `subject` is
still an opaque app-assigned string — a service identity is just a
subject value like `"service:billing-worker"`, not a new concept Monk
has to understand.

What's deliberately not included, for the same reason roles/permissions
are out of scope for the rest of this doc: no scopes on a key, no
self-serve rotation endpoint, no per-key rate limiting. Rotation is
"mint a new key, revoke the old one" — two calls the app already has.

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
- **Read the secret once, at boot, on the main Ractor.** The reasons
  are ordinary ones, none of them dependent on Ractor semantics: fail
  fast and loudly if the secret is missing (ADR 0003's spirit), keep an
  `ENV` lookup off the per-request path, and hold the value as one
  frozen String the whole worker pool can read.
- **Unresolved, deliberately: is `ENV` readable from a non-main Ractor
  on Ruby 4?** Monk targets 4.0.6 (`.ruby-version`; the gemspec
  requires `>= 4.0`), and that question has not been answered on 4.x.
  It was probed on 3.3.6 during this design pass — reads worked and
  returned the correct value — but that measurement is **off-target and
  is not carried over here**; this project's own history (the Phase 0
  Sequel spike, the Phase 4 and 5 freezing findings) is a standing
  argument against porting Ractor behavior across versions by
  assumption. It could not be measured in the session that wrote this
  doc: Ruby 4 source is unreachable from that environment (the network
  policy answers 403 for `cache.ruby-lang.org` and
  `codeload.github.com`), and no 4.x toolchain was installed.
  `PLAN-AUTH.md` Phase 5 carries it as an explicit step,
  because it isn't only an auth question: `lib/monk/base.rb:79` reads
  `ENV["MONK_ENV"]` on every request, inside whichever worker Ractor is
  serving it, to decide whether to log. If a non-main Ractor on 4.0 sees
  a different answer than the main one does, request logging silently
  stops honoring `MONK_ENV=production` under a real `kino` pool.
- **Email delivery stays outside the framework.** A mailer object
  captured in a route closure fails `freeze!` with
  `UnshareableRouteError`, and rightly so. `Monk::Auth.request_login`
  should *return* the raw token and let the app deliver it; Monk taking
  on SMTP would be a much larger scope claim than auth.
- **Helpers, not state.** `require_user!` / `current_subject` — and, for
  the browser case, `set_session_cookie` / `clear_session_cookie` /
  `require_csrf!` — live in a `Monk::Auth::Helpers` module mixed into the
  `Context` class. A `Context` is per-request and never crosses Ractors
  (`CONTEXT.md`), so helpers holding request-scoped memoization are exempt
  from the app's shareability constraints. `require_csrf!` is a no-op when
  `current_subject` resolved from `Authorization` rather than the cookie —
  it only ever guards the cookie-authenticated path.

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
    # redirect_to: nil => API/Bearer path; a path => browser/cookie path
    token = Monk::Auth.request_login(params[:email], redirect_to: params[:redirect_to])
    Mailer.magic_link(params[:email], token)  # app's job, not Monk's
    json(ok: true)                            # never echo the token
  end

  get("/auth/callback/:token") do
    session = Monk::Auth.redeem(params[:token])
    halt 401, "invalid or expired link" unless session

    if session[:redirect_to]
      set_session_cookie(session)             # HttpOnly + a readable CSRF cookie
      redirect session[:redirect_to]           # 302, no token in the URL
    else
      json(token: session[:token], expires_at: session[:expires_at])
    end
  end

  get("/me") do
    subject = require_user!   # Bearer, else the session cookie; halts 401
    json(subject: subject)
  end

  post("/orders") do
    subject = require_user!
    require_csrf!             # cookie-authenticated only; no-op for Bearer
    # ...
  end

  delete("/auth/session") do
    require_csrf!
    Monk::Auth.revoke(require_token!)
    clear_session_cookie
    json(ok: true)
  end
end

# Out-of-band — a rake task or an app-built admin route, never a public
# endpoint. Shown once; only the hash is ever persisted.
key = Monk::Auth.create_api_key(subject: "service:billing-worker")
# => "mk_9f2a3c1d..."
```

`Monk::Auth` is opt-in the way persistence backends are — `require
"monk"` alone must not load it, since it depends on a persistence
backend the app may not use.

## The browser case: cookies, redirects, and CSRF

This supersedes the old Phase 9 deferral. A browser-facing app gets the
session token the same way an API client does — `Monk::Auth.redeem`
returns the identical Hash — but the callback route decides how to hand it
back based on whether the app told it there's a browser on the other end.

**`redirect_to` decides the response shape.** `POST /auth/request` accepts
an optional `redirect_to` (a same-app path, validated against an allowlist
the app configures — never an open redirect to an arbitrary host) and
carries it through to the `login_tokens` row as a plain column. `GET
/auth/callback/:token`:

- **no `redirect_to` on the row** → today's behavior, unchanged: redeem,
  respond `200 json(token:, expires_at:)`. This is the API/Bearer path.
- **`redirect_to` present** → redeem, `Set-Cookie` the session token
  (`HttpOnly; Secure; SameSite=Lax; Path=/`), then `302` to `redirect_to`
  with no token anywhere in the URL. This is redeem-then-redirect, the fix
  for `Referer` leakage this doc already flagged — the reason it needs
  prerequisite #2 (response headers) and `Context#redirect`, both Phase 9
  in `PLAN-AUTH.md`.

Cookie `expires_at` mirrors the `sessions` row's `expires_at` (`Max-Age`
matching the 14-day TTL) — an absolute expiry on the cookie itself, not
just server-side, so a stale cookie a browser still holds past that window
doesn't round-trip to the server at all.

**Logout** (`DELETE /auth/session`) must clear the cookie in the same
response that revokes the row — `Set-Cookie` with an already-expired
`Max-Age=0` — otherwise the browser keeps presenting a token the server has
already revoked (harmless, since `verify` still rejects it, but worth
doing so the browser's own state matches the server's).

### CSRF: stateless double-submit, no third table

A cookie is sent automatically by the browser on every request to the
cookie's origin, including ones a malicious third-party page triggers —
the classic CSRF vector. Bearer requests are exempt by construction (a
page has no channel to set a header on a cross-origin request its own JS
didn't originate), so this section applies only to state-changing routes
authenticated via the cookie fallback, never to routes authenticated via
`Authorization`.

Rejected: a `csrf_tokens` table. It would add a third schema object and a
lookup to a design whose whole point is that verification is pure
computation over what's already at hand. Instead, the CSRF token is
**derived, not stored**: `HMAC-SHA256(secret, session_token)`, the same
frozen `secret` `Monk::Auth.configure` already reads once at boot. Anyone
holding the session cookie can compute the matching CSRF value; anyone who
doesn't have the cookie (a cross-origin attacker page) can't produce it,
because they can't read the `HttpOnly` cookie to feed into the HMAC even
though the algorithm is public.

Flow:

1. The callback response (cookie path above) also sets a **second**,
   **non**-`HttpOnly` cookie — `csrf_token=<the HMAC value>`, `Secure;
   SameSite=Lax` — readable by the app's own JS precisely because it must
   be echoed back.
2. The app's JS reads that cookie and sends it as a header
   (`X-CSRF-Token`) on every state-changing (`POST`/`PUT`/`PATCH`/`DELETE`)
   request. This is the "double submit": the same value arrives twice, once
   automatically (cookie) and once only same-origin JS could have attached
   (header).
3. `Monk::Auth::Helpers` verifies, for cookie-authenticated state-changing
   requests only: `X-CSRF-Token` header equals
   `HMAC-SHA256(secret, session_cookie_value)`. Compare with
   `OpenSSL.secure_compare`, per the existing token-comparison rule below.
   Mismatch or missing header → `403`, distinct from the `401` an invalid
   session produces.
4. `GET`/`HEAD` routes never mutate state — a rule the app must hold, since
   `SameSite=Lax` only withholds the cookie from cross-site requests using
   unsafe methods, not from a cross-site top-level `GET` navigation. This
   is worth stating because it's the one place `SameSite=Lax` alone would
   otherwise look sufficient and isn't.

`SameSite=Lax` on the session cookie is defense-in-depth underneath this,
not a replacement for it: `Lax` already blocks the cookie from riding along
on a cross-site `POST`, but the double-submit check is what makes CSRF
protection independent of which browser (or how current a browser) is
making the request.

## The WebSocket case: identity across a second process

`docs/websocket.md` Phase 5 (step 20) left the token-carrier question for
the WS handshake explicitly open, because a browser's `new WebSocket(url)`
constructor cannot set custom headers — so the plain `Authorization:
Bearer` pattern above doesn't transfer unchanged. It resolves without a
third mechanism, from two facts neither doc previously used together:

1. **Cookies are not port-scoped.** RFC 6265 matches a cookie's `Domain`
   and `Path`, never its port. `docs/websocket.md`'s recommended topology —
   a reverse proxy routing `/ws` on the *same host* to the WS process, and
   everything else to Kino — means the session cookie set by the HTTP
   process is sent automatically by the browser on the WS handshake
   request too, exactly as it would be on any other same-origin request.
   No query-string token, no first-message auth handshake: the browser
   does this for free the same way it does for an ordinary `fetch`.
   (If the WS process instead lives on a distinct **subdomain** rather
   than a shared-host path, the cookie needs an explicit `Domain=` set to
   the shared parent domain, or this stops working — call this out in
   whichever topology `PLAN-WEBSOCKET.md` Decision 4 lands on.)
2. **Only the browser's `WebSocket` JS API is header-restricted.** A
   non-browser WS client — a server-to-server caller, a CLI tool — is
   making a plain HTTP request for the handshake and can set
   `Authorization: Bearer <token>` on it exactly like an HTTP API call.
   Nothing about the WS upgrade restricts that; the restriction is
   browser-JS-specific, not protocol-specific.

So: **browser-originated connections authenticate via the cookie, carried
automatically; non-browser connections authenticate via
`Authorization: Bearer`, set directly on the handshake request.**
`Monk::Auth.verify` runs identically either way — it was already designed
to be storage-shaped, not transport-shaped, so nothing about the
verification code path changes for WebSocket at all.

**This does not eliminate the CSRF-shaped risk — it moves it.** A
cross-origin page can still do `new WebSocket("wss://victim-host/ws")` and
have the browser attach the victim's cookie to that handshake, the
WebSocket analogue of CSRF (Cross-Site WebSocket Hijacking). `SameSite=Lax`
is not a reliable defense here: whether browsers apply `SameSite` cookie
rules to a WebSocket handshake at all has historically been inconsistent
across implementations, so unlike the HTTP CSRF case above, this one
cannot lean on `SameSite` even as defense-in-depth. The double-submit
header check above also doesn't apply — a WS handshake has no place for
the app to attach a custom header from browser JS before the connection
opens. The mitigation is instead the standard one for this exact class of
attack: **the WS process validates the `Origin` header on every handshake
against an explicit allowlist of the app's own origins**, rejecting the
handshake (before it ever reaches `Monk::Auth.verify`) if `Origin` doesn't
match. Unlike arbitrary headers, `Origin` is set by the browser itself and
cannot be overridden by page JS, which is exactly why it's the accepted
mitigation for CSWSH regardless of `SameSite` behavior. `PLAN-WEBSOCKET.md`
Phase 5 should carry this as an explicit step alongside step 20/21, not as
a follow-on hardening pass.

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
- **Cookies need `HttpOnly; Secure; SameSite=Lax`**, and bring CSRF into
  scope for state-changing routes authenticated that way — see "The
  browser case" above for the double-submit design, and "The WebSocket
  case" for why WS needs `Origin` validation instead of the double-submit
  check.
- **Cross-Site WebSocket Hijacking (CSWSH).** A cookie-authenticated WS
  handshake is forgeable cross-origin the same way a CSRF'd form post is,
  but neither `SameSite` nor a CSRF header defends it (see "The WebSocket
  case"). `Origin` allowlist validation on every handshake is the
  mitigation, not optional hardening.

## Open questions

1. ~~Bearer or cookie first?~~ **Resolved: both, chosen by client type,
   not sequenced.** API/S2S callers use Bearer; browsers use the cookie
   ("The three transports, one token model" above); WebSocket reuses
   whichever of the two the connecting client already has ("The WebSocket
   case"). Prerequisites #2–#4 (response headers, query/body parsing,
   middleware) are therefore in scope for `PLAN-AUTH.md` now, not deferred
   — see its Phase 9.
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
5. **How many raw characters go into `prefix`?** Recommendation: 8,
   matching common practice (GitHub, Stripe). It's derived only at mint
   time from the raw token, never backfilled, so the choice doesn't need
   a data migration to revisit later.

## Explicitly out of scope

No passwords, ever (that's the point). No OAuth/OIDC/SAML, no WebAuthn/
passkeys, no TOTP or second factors, no "remember this device", no
account/user schema, no email delivery or templating, no
authorization/roles/permissions (this doc is authentication only), no
session listing/"log out everywhere" UI, no JWT (option B is a plain HMAC
token, not a JWT — no `alg` field, no algorithm negotiation, no library),
no cross-origin CORS credential-sharing design (cookies here are strictly
same-origin; a third-party frontend on a different origin is an API/Bearer
consumer, not a cookie consumer).
