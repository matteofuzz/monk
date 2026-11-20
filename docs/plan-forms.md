# 0.26: Richer HTML support, forms first — plan

Status: draft, 2026-11-20. Roadmap item 5 (`docs/roadmap.md`).

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

- **Flash**: a one-shot message surviving the redirect after a POST.
  Needs a cookie, so a public cookie API (today private to auth) may come
  with it.
- **Form helpers**: fields filling their value back after a failed submit,
  `select` options. Plain ERB (`value="<%= params[:email] %>"`) may be
  enough, in which case the guide shows the pattern and Monk adds nothing.
- **Validation errors**: a convention for an errors hash and showing a
  message next to its field. Possibly only a documented pattern.
- **Redirect guard**: `redirect` refusing another origin unless asked,
  so `redirect(params[:return_to])` isn't an open redirect.

## Out of scope

Multipart (decision 1); tag builders and `link_to`; `content_for`/named
slots; Live intercepting form submits (a full POST-redirect-GET already
works with Live).

## Steps

1. Status fix (A5), with a test that fails today.
2. Params parser (decision 4) for the query string, with its limits.
3. Urlencoded body, body size limit, 415 for multipart, 400 for bad JSON
   (A1). Check Kino's limit first.
4. Method override (A4).
5. Cross-origin protection and its opt-out (A2), including a
   Ractor-integration test and the Live demo's form.
6. `require_csrf!` form field and the hidden-field helper (A3); move the
   scaffolded auth pages to plain forms if simpler.
7. Security headers (A6), if kept.
8. Guide `docs/guides/forms.md`: a form end to end, failed submit with
   422, the direct-upload-then-post pattern, the cross-origin opt-out.
   Update `docs/design/views.md`'s "no form helpers" note and the agents
   templates.
9. Part B, item by item, recording each decision here.

## Open

- Body size limit default, and how it's configured.
- Cross-origin opt-out DSL; `Host` vs `public_url` behind proxies.
- Hidden-field helper name.
- Security headers: on by default, scope, opt-out.
- Part B, item by item.
