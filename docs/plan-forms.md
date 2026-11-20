# 0.26: Richer HTML support, forms first — plan

Status: in progress. Drafted 2026-11-20; steps 1-8 built 2026-11-20.
Roadmap item 5 (`docs/roadmap.md`).

Make a plain `<form method="post">` work in a Monk app, safely, with no
JavaScript: the body parsed into `params`, cross-site requests refused,
the CSRF token sent as a form field, and a failed submit re-rendered with
the right status.

## Guiding principle: as light as possible

Monk must stay small and easy to read for humans and agents alike. Every
feature here is weighed against the code and the concepts it adds, and the
default answer to "should Monk do this?" is no, unless a plain HTML form
can't reasonably work without it.

So this plan is in two parts with different levels of commitment:

- **Part A, the basics, is committed.** Without it a plain form doesn't
  work, or isn't safe.
- **Part B, form helpers, is decided while building A**, one item at a
  time, by writing real forms in a scaffolded app and seeing what hurts.
  Each B item lands only if it saves more than it costs; "Rails has it" is
  not a reason. Plain HTML in templates remains the default
  (`docs/design/views.md`: "the templates are HTML"), and a B item that's
  turned down is recorded under Decisions with why.

## What exists today

- **Params.** `Base.parse_params` (`lib/monk/base.rb`): the query string
  via `URI.decode_www_form` (flat, last repeated key wins, symbol keys),
  then a JSON body when `Content-Type` contains `application/json`
  (malformed JSON becomes `{}`), then path params on top. Rack's parser
  isn't used: it memoizes an unfrozen parser in a module ivar, which a
  worker Ractor can't read.
- **Form bodies.** Neither `application/x-www-form-urlencoded` nor
  `multipart/form-data` is parsed: a plain POST arrives with empty
  `params`. The auth login page posts with `fetch` and JSON for this
  reason.
- **Verbs.** GET, POST, PUT, PATCH, DELETE routes; `resources` maps update
  to PATCH/PUT and destroy to DELETE, which an HTML form can't send.
- **Status.** `dispatch` answers a route block's return value with a
  hard-coded `200` (`base.rb:174`), so `self.status = 422` is ignored;
  only `halt(422, render("new"))` works.
- **CSRF.** Only with `monk add auth`: stateless double-submit
  (`docs/design/auth-sessions.md`), `csrf_token` cookie = HMAC of the
  session token, checked by `require_csrf!` against the `X-CSRF-Token`
  header only. No form field, no view helper. Without auth there's no
  protection at all (the Live demo's `<form method="post">` has none).
- **Limits and headers.** No request body size limit in Monk (Kino's
  own limit, if any, not checked yet). No security headers on responses.
- **Uploads.** `Monk::Storage` uploads from the browser straight to the
  bucket (ADR 0018); the app never sees a file body.

## Decisions

1. **No multipart parsing.** Files go through `Monk::Storage`'s direct
   upload, and a form without files is sent urlencoded (the browser's
   default). A form with both uploads the file first with JS and posts
   the storage key with the rest; the forms guide shows this. A
   `multipart/form-data` request to a route gets **415**, not silently
   empty `params`.
2. **Cross-origin protection in core, on by default, with a per-route
   opt-out.** Works with or without auth, needs no token or session, and
   covers every route without anyone remembering to call it. Modeled on
   Go 1.25's `http.CrossOriginProtection`: for POST, PUT, PATCH and
   DELETE, `Sec-Fetch-Site: same-origin` or `none` passes; any other value
   gets 403; without it, `Origin` must match the request's `Host`; with
   neither header (curl, server-to-server) the request passes. A route
   opts out for webhooks and the like; exact DSL in step A2.
3. **The CSRF token stays, as defence in depth for cookie sessions.**
   `require_csrf!` also accepts a `csrf_token` param, and auth adds one
   helper writing the hidden field. The header keeps working for `fetch`.
4. **Nested params, with limits and a small syntax.** `a[b]=1` →
   `{a: {b: "1"}}`, `a[]=1&a[]=2` → `{a: ["1", "2"]}`, nesting allowed
   (`a[b][c]`). Not supported: arrays of hashes (`a[][b]`); a form that
   needs them is better split or sent as JSON. Limits on depth, key count
   and array size, with 400 past them. Same parser for the query string
   and the urlencoded body; our own code, not Rack's.
5. **Method override from a POST body only.** `_method=patch|put|delete`
   in a urlencoded POST body changes the verb before routing. Never from
   the query string, never on GET.

Settled while building steps 1-6:

6. **One cap on parsed bodies, 1 MB, a constant** (`Base::MAX_PARSED_BODY`):
   413 past it, for form and JSON bodies alike (JSON had no cap before).
   Not a setting. Kino already refuses any body over its `max_body_size`
   (50 MB by default) with a 413, so Monk needs no limit of its own beyond
   what it parses. Param limits are constants too: `Params::MAX_PAIRS`
   (1000) and `Params::MAX_DEPTH` (8).
7. **400 for params that can't be read**: a key used as both a value and
   a hash (`a=1&a[b]=2`), past a limit, malformed JSON, or a JSON body
   that isn't an object (before, a JSON array crashed `dispatch`). A bad
   `%`-sequence is not an error: `URI.decode_www_form` keeps it as written.
8. **The opt-out is `allow_cross_origin: true`** on the route
   (`post("/hook", allow_cross_origin: true) { ... }`), spelled out so an
   agent reading it can't misread it. `resources` has none: a webhook is
   a single route.
9. **Origin is compared with `Host`, not `public_url`.** Every current
   browser sends `Sec-Fetch-Site`, so the `Origin` fallback only serves
   older ones; a proxy that rewrites `Host` breaks only those. Not worth a
   dependency on an app setting.
10. **The override rewrites `env["REQUEST_METHOD"]`**, so the request log
    and `env` show the verb that was routed.
11. **`csrf_field`** is the helper's name; it writes nothing without a
    session cookie. `require_csrf!` reads the header first, then
    `params[:csrf_token]`, and only a String counts (a nested
    `csrf_token[x]` is a 403, not a 500).
12. **The scaffolded login page is a plain form now**, with no script: the
    route renders it again with `@error` and `halt(422 | 429, render(...))`,
    or with `@sent`. Logout's example is a form with `csrf_field` and
    redirects to `/login`.
13. **Security headers on every response, by default** (`Base::SECURITY_HEADERS`):
    `x-content-type-options: nosniff`, `content-security-policy:
    frame-ancestors 'none'`, `referrer-policy:
    strict-origin-when-cross-origin`, merged under the app's own headers
    in `Base.call`, so static files, 404s and refusals carry them too. A
    route replaces one by setting it in `headers`; no switch to turn them
    off. An app that sets its own `content-security-policy` replaces
    `frame-ancestors` with it, so it should include it.
14. **`redirect` goes only to this app** unless `allow_other_host: true`
    (Part B; the name agents know from Rails). A path, or an http(s) URL
    whose host and port equal the request's `Host`; control characters,
    spaces, backslashes, an empty location and a scheme without a host are
    refused, as browsers would read them as another host. Anything else
    raises `Monk::UnsafeRedirectError` (a 500 unless the app handles it,
    e.g. `error(Monk::UnsafeRedirectError) { redirect "/" }`) rather than
    silently going home: the bug shows up while writing the route. The
    storage download example and guide pass `allow_other_host: true`.
15. **Flash is one keyword and one reader**: `redirect(path, flash:
    "Saved.")` and `flash` (a String or nil), not a hash of kinds. A
    flash only matters after a redirect, and a failed submit re-renders
    with its own `@error`, so one plain message covers it. It's a cookie
    (`flash`, URL-encoded, `HttpOnly`, `SameSite=Lax`, `Secure` but in
    development, 60 s), cleared by the response of the page that reads it.
    Not signed: a forged one is only text, escaped when shown. Reading and
    setting cookies moved from `Monk::Auth::Helpers` into `Context` as
    private methods both use; no public cookie API. The scaffolded layout
    shows it, and auth's logout example uses it.

## Part A: the basics (committed)

### A1. Parsing a form body

- Parse `application/x-www-form-urlencoded` bodies into `params`, between
  the query string and path params in the merge order.
- One parser for query string and body with the nested syntax and limits
  of decision 4.
- A body size limit, checked against `Content-Length` and while reading:
  413 past it. Default to be chosen (1 MB?), configurable. Check first
  what Kino already enforces.
- `multipart/form-data` → 415 (decision 1).
- Malformed JSON → 400, not `{}` (same code path, small).

### A2. Cross-origin protection

- Check in `dispatch`, after the route is found (the opt-out is on the
  route) and before its block runs; 403 with an empty body.
- Opt-out DSL, simplest that reads well, e.g.
  `post("/webhooks/stripe", cross_origin: true) { ... }`.
- Trusted extra origins (an app served from two hostnames): only if a
  real case shows up. Behind a proxy that rewrites `Host`, `Origin` won't
  match: document it, and decide in the step whether `public_url` should
  be the fallback comparison instead of `Host`.
- The Live demo's form is now protected with no change to it.

### A3. CSRF token in forms (auth)

- `require_csrf!` accepts `params[:csrf_token]` or the header.
- One helper in `Monk::Auth::Helpers` writing
  `<input type="hidden" name="csrf_token" value="...">` for the current
  session (name to settle: `csrf_field`?).
- The scaffolded login page and the commented logout route move to a
  plain form, if that's simpler than the `fetch` they use today.

### A4. Method override

- Decision 5, applied before `find_route`; the body is parsed before
  routing for POSTs with a form content type.

### A5. Status

- `dispatch` answers with `context.status`, so
  `self.status = 422; render "new"` works. A bug fix more than a feature:
  goes in the CHANGELOG as such.

### A6. Security headers (probably)

Default response headers, overridable through `headers`:
`X-Content-Type-Options: nosniff`, `Content-Security-Policy:
frame-ancestors 'none'` (clickjacking), `Referrer-Policy:
strict-origin-when-cross-origin`. Decide in the step whether they're on
every response or only HTML ones, and how an app turns one off.

## Part B: helpers (decided while building)

Candidates, none committed. Each is tried against real forms after A and
kept only if it clearly pays for itself.

- **Flash**: kept, built (decision 15).
- **Form helpers**: fields filling their value back after a failed submit,
  `select` options. Plain ERB (`value="<%= params[:email] %>"`) may be
  enough, in which case the guide shows the pattern and Monk adds nothing.
- **Validation errors**: a convention for an errors hash and showing a
  message next to its field. Possibly only a documented pattern.
- **Redirect guard**: kept, built (decision 14).

## Out of scope

Multipart (decision 1); tag builders and `link_to`; `content_for`/named
slots; Live intercepting form submits (a full POST-redirect-GET already
works with Live).

## Steps

1. Done. Status fix (A5), with a test that fails today. Error handlers
   (`error(Class)`, `error(404)`) can set the status too.
2. Done. Params parser (decision 4) for the query string, with its
   limits: `lib/monk/params.rb`.
3. Done. Urlencoded body, body size limit, 415 for multipart, 400 for bad
   JSON (A1; decisions 6, 7).
4. Done. Method override (A4; decision 10).
5. Done. Cross-origin protection and its opt-out (A2; decisions 8, 9),
   with a worker-Ractor test of a form post (it caught two `%w[].freeze`
   constants a worker couldn't read). The Live demo's form needed no
   change.
6. Done. `require_csrf!` form field and `csrf_field` (A3; decisions 11,
   12); `docs/guides/routing.md` and `docs/design/auth-sessions.md`
   updated for the new behaviour.
7. Done. Security headers (A6; decision 13).
8. Done. Guide `docs/guides/forms.md` (its example checked against the
   code), a README row, `docs/design/views.md`'s "no form helpers" note,
   the storage guide's 415, and a cross-site rule in the base app's
   `AGENTS.md`. At release: the CHANGELOG, and in
   `docs/guides/upgrading.md` what an existing app must do: routes taking
   another site's browser requests need `allow_cross_origin: true`, JSON
   bodies are capped at 1 MB, and the new login page is optional.
9. Part B, item by item, recording each decision here.
   - Done. Redirect guard (decision 14). At release, the upgrade guide:
     a redirect to another host needs `allow_other_host: true`.
   - Done. Flash (decision 15).

## Open

- Part B, item by item.
