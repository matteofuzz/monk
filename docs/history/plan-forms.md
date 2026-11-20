# 0.26: Richer HTML support, forms first — plan

Status: done (2026-11-20). Drafted, built and checked 2026-11-20, Part C
included; released in 0.26.
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
16. **No form helpers, and no validation API.** Writing a login and a
    many-field form (text, date, number, select, multiple select, radios,
    a checkbox, new and edit through one partial) in plain ERB showed
    fields filling back in one short expression each. The only noise is
    `<%= "selected" if ... %>` per option, readable and known to every
    agent. Errors are a Hash from a plain model method, shown by a
    two-line partial. Both are documented patterns instead: the forms
    guide's two examples (run against Postgres) and a `## Forms` section
    in the scaffolded `AGENTS.md`, which an app's agents read without
    Monk's docs.
17. **A stale `csrf_token` cookie is reissued** (C2). `current_subject`,
    on the cookie path with a valid session, sets `csrf_token` again when
    the request's doesn't match the session (or is missing), with the
    session's remaining lifetime; `require_csrf!` calls it before its 403,
    so the retry passes. One HMAC per signed-in request; nothing sent when
    it matches. `Monk::Auth.verified_session` gives the expiry (`verify`
    is built on it). Logout keeps `require_csrf!`: once reissued, it
    passes like any route.

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
- **Form helpers**: not built (decision 16).
- **Validation errors**: a documented pattern, no code (decision 16).
- **Redirect guard**: kept, built (decision 14).

## Part C: fixes from the first app's deployment

Three things found running monk_talk on a real server and an iPhone
(2026-11-20). Not forms, but small and in the way of any Monk app shipped
the same way, so they ride in this release. Each needs its own look
before it's built; the notes are a starting point.

### C1. A closed iPhone app reads as online for about a minute

**Found:** closing the installed app on an iPhone leaves the person
online for about a minute, so a push meant for when they're gone is
skipped.

**Today:** the Live client reports hidden and visible on
`visibilitychange` only (`lib/monk/live/client/monk_live.js`). The
WebSocket server closes a socket silent for two ping intervals, and the
scaffolded `bin/websocket_server` pings every 25 s: about 50 s, plus
`Monk::Presence`'s 20 s grace before offline.

**Options:**

- The client also reports hidden on `pagehide`, which may fire where
  `visibilitychange` doesn't (closing from the app switcher). The page
  goes away while away, not online, and push isn't skipped for an away
  person. Cheap; whether iOS fires it on close has to be measured on the
  device.
- The server closes a silent socket sooner: a shorter interval for
  everyone, or a shorter limit only for a socket whose page said hidden.
  More sockets dropped and reconnected on flaky mobile networks.

**Measured in monk_talk (2026-11-20):** with the app in the background a
message notifies; swiped away, a message within about a minute sends no
push at all, because presence still reads online; two minutes after, it
arrives. iOS froze the page before it reported itself hidden, so
`visibilitychange` never reached the server, and `pagehide` may not
either.

**Where the minute comes from:** the server already has a fallback for a
page frozen before it says hidden: `Live::Session` turns a socket Away
once no Live ping has come for `visible_for = 2 × HEARTBEAT` (50 s),
checked on the server's own ping every 25 s, so 50-75 s after the last
ping (ADR 0019). A check of its own per connection, every 10 s, was
measured and dropped: at 15K sockets it took the WebSocket process from
40% to 83% CPU.

**Prepared (2026-11-20), client side:** `monk_live.js` also says hidden
on `pagehide` and `freeze`, through the same `goneHidden` as
`visibilitychange`. A page closed or frozen with no `visibilitychange`
first now reads Away at once, if the browser runs the page long enough
to send it. Browser tests dispatch both events on a visible page, with
a server silence window far longer than the test, and see Away at once
(both time out without the change).

**Measured on the iPhone (2026-11-20),** with `monk_live.js` patched
by hand into monk_talk staging's web container: the app open and
visible, swiped away from the app switcher, the dot on a second device
stayed **green for about 21 s, then turned to reachable**. So iOS
closed the socket at once, without running `pagehide`, `freeze` or a
late `visibilitychange` first: the minute's silence window (S1, S2
below) never came into it. What held the person online was the grace:
a closed socket's row kept its last status, online, for 20 s.

**Fixed (2026-11-20), server side:** a socket that closes marks its
row gone *and away* (`Store`'s `FLUSH_SQL` and `REWRITE_SQL`), so the
person reads away at once, then offline after the grace, and a message
in between gets its push. Rows a stopping process marks gone
(`MARK_ALL_GONE_SQL`, a deploy) keep their status, so a deploy still
changes nobody's. A page reconnecting after a network change shows the
away ring until it's back; it never shows offline. ADR 0019 amended.

Kept from the preparation: the client change stays, for a browser that
does run `pagehide` or `freeze` before closing (a desktop tab, Chrome).
S1 and S2 stay unbuilt: they matter only for a page frozen with its
socket still open, and the same day's tests showed none. Locking the
phone, going to the home screen, or switching to another app each read
**away at once, then reachable about 20 s later**: the page says hidden
before iOS freezes it, then iOS drops the socket and the grace runs
out. To revisit only if an iPhone is ever seen reading online for a
minute.

### C2. A session whose CSRF cookie no longer verifies is stuck

**Found:** after `AUTH_SECRET` changed (restoring a backup), a signed-in
browser still read its pages, but every route calling `require_csrf!`
answered 403, logout included, until its cookies were cleared.

**Why:** the session lives in the database as a SHA-256 of its token,
which doesn't depend on the secret, so it still verifies. The
`csrf_token` cookie is `HMAC(AUTH_SECRET, session token)`, set only at
login, so it no longer matches. Since 0.26 a form with `csrf_field` is
not stuck: the field is computed from the session with the current
secret. A `fetch` that sends the cookie's value is.

**Options:**

- Reissue `csrf_token` when a request has a valid session and a
  `csrf_token` cookie that doesn't match it: one HMAC per signed-in
  request, and the next `fetch` works. Where it lives (in
  `current_subject`, or on `require_csrf!`'s 403) is to settle.
- Let logout through without the token. Since 0.26 Monk's cross-origin
  check already refuses another site's logout, so the token adds little
  there, but it only unsticks logout.

**Leaning:** reissue; logout then needs no special case.

**Built (decision 17).**

### C3. Deploying an app with websocket, jobs and auth

**Found:** the Compose stack and the Hetzner scripts written for the
first app (`../monk_talk`, commit `96357f1`, its
`doc/hetzner-deployment_plan.md`) are what any Monk app with websocket,
jobs and auth needs. They were themselves adapted from a second app's
(standup-quiz), with extraction to Monk planned "after a third".

**Today:** `docs/guides/deploying.md` section 4 has a Compose file and
Caddy's `/ws` route, written by hand from the guide. Secrets, push keys,
the log volume and health checks are left to the reader.

**What monk_talk's files are made of:**

| Part | Generic? |
|---|---|
| `compose.yaml`: the image run as `web`, `ws` (`bin/websocket_server`) and `jobs` (`bin/jobs`); Postgres with a `pg_isready` health check the Ruby services wait on; Caddy; `stop_grace_period: 35s` (over kino's and `bin/jobs`' 30 s drains); `restart: unless-stopped`; a `log` volume | Yes. Which services appear follows the installed modules: `ws` with websocket, `jobs` with jobs, `postgres` with postgres, `redis` with redis. |
| `Caddyfile`: `{$SITE_ADDRESS}`, `/ws*` to `ws:9293`, the rest to `web:9292`, same host so the session cookie reaches the handshake | Yes, with websocket; without it, one `reverse_proxy`. |
| `.env.production.example`: `MONK_ENV=staging`, `PUBLIC_URL`, `SITE_ADDRESS`, then each module's settings | Mostly. Each Monk generator already declares its env vars (`env :example`, `set_before_production ... placeholder: true`), so the file can be built from the installed modules. `MESSAGE_KEY` and `DEPLOY_LABEL` are the app's own. No inline comments: the scripts read values with `sed`. |
| First deploy: secrets made on the host (`openssl rand -hex 32` for `AUTH_SECRET`, one password for `DB_PASSWORD` and `POSTGRES_PASSWORD`, `monk push keys` run in the built image), file mode 600 | Yes, following the modules. |
| `smoke_test.sh`: containers running, no pending migrations, https with the http redirect, the PWA files, the page's push key equal to the server's, a login link sent through `bin/jobs` (with `MAIL_URL=log://`), the `/ws` handshake answering 101 | The checks are generic, and mostly what 0.27's `monk check` is for. The version and badge checks are the app's. |
| `deploy/hetzner/`: `hcloud` server and firewall, cloud-init (Docker, swap, capped logs), DNS in Hetzner, `git archive` over SSH and a build on the host, `snapshot.sh`/`restore.sh`, `restore_dump.sh`, `mail.sh` | No: one host's tooling and one person's accounts. |

**Lessons for Monk, whichever form this takes:**

- **The env file is a backup.** A dump restored with a new `AUTH_SECRET`
  left every session stuck (C2), with a new VAPID pair every push
  subscription dead, with `MESSAGE_KEY` lost every message. monk_talk
  saves `.env.production` beside each dump. Worth saying in
  `deploying.md`, whatever C2 does.
- **Monk logs to `log/<MONK_ENV>.log`, not stdout**, so a container
  needs a log volume and `docker compose logs` shows nothing of the app.
  Whether Monk should also log to stdout in a container is a question of
  its own.
- **The lockfile's platforms.** monk_talk's existing lockfile listed only
  `arm64-darwin` and needed `bundle lock --add-platform x86_64-linux
  aarch64-linux`; `deploying.md` and the scaffolded Dockerfile say a
  plain `bundle install` locks every platform, which seems to hold only
  for a new lockfile. To check, then fix the docs or the scaffold.
- **`VAPID_CONTACT`**: a production-like run on `https://localhost` fails
  the boot (Apple refuses a localhost contact), so a local run sets it.
  Already Monk's behaviour; the env example says so.

**Design: `monk add deploy` for the stack; Hetzner and Brevo as docs.**
(Decided 2026-11-20: no provider in the command for now, and no tests of
host scripts.)

- **`deploy`, a module.** It writes `compose.yaml`, the `Caddyfile`,
  `.env.production.example` and `bin/deploy_env` (run on the host: fills
  in the secrets, `monk push keys` in the built image when push is
  installed), all from the installed modules; a later `monk add` of
  another module adds its service and settings, as generators already do
  for `SETUP.md`. Installed when `compose.yaml` exists. Nothing in it
  names a host: it runs on any Linux box with Docker.
- **Hetzner and Brevo, in a guide**: `docs/guides/deploy-hetzner.md`,
  everything needed to reproduce the deploy monk_talk runs, tested there
  (25 smoke checks, real mail with DKIM and DMARC passing, push on an
  iPhone, both backup tests):
  - **Accounts, once**: a Hetzner Cloud project and a Read & Write API
    token (`hcloud context create <project>`), an SSH key; a domain with
    its DNS zone in Hetzner (or `<ip>.sslip.io`, no DNS, a URL that
    changes with the IP); Brevo with the domain authenticated (DKIM,
    DMARC), an SMTP key per app, the sender on that domain and not on
    the app's subdomain, the free plan's 300 mails a day.
  - **The server**: `cx23` (2 vCPU, 4 GB, 40 GB, about €7.31 a month,
    billed by the hour), Ubuntu 24.04, a firewall allowing 22, 80, 443
    and 443/udp, cloud-init for Docker, Compose, 2 GB of swap and capped
    container logs; the exact `hcloud` commands.
  - **DNS**: the A record pointed with `hcloud zone rrset`, a 300 s TTL,
    waiting until a public resolver sees it before Caddy asks for its
    certificate; hyphens, not underscores, in the host name.
  - **Shipping**: `git archive HEAD` over SSH, built on the server (no
    registry), the env file kept across deploys, `bin/deploy_env` on the
    first one, `bin/setup_db`, then `docker compose up -d`.
  - **Mail**: `MAIL_URL=smtp://<login>:<key>@smtp-relay.brevo.com:587`
    with an `@` in the login percent-encoded, in single quotes so Compose
    doesn't expand a `$`; the SMTP key over stdin, never in a command
    line; `log://` until then, reading login links from the log.
  - **Checking it**: the checks monk_talk's smoke test makes, as
    commands (until `monk check`, 0.27, does them).
  - **Backups**: a snapshot with the server shut down (Postgres
    consistent), `--destroy` to stop paying; a `pg_dump` with the env
    file beside it, since a restore without its `AUTH_SECRET`, VAPID pair
    or the app's own keys loses sessions, push subscriptions or data;
    restoring onto a fresh server with that env file.
  - **Costs and capacity**: what the box holds, as monk_talk estimated.
  The guide links to `docs/guides/mail.md`'s Brevo section rather than
  repeating it.
- **For agents.** The gem ships no `docs/`, so an app's agents read only
  its `AGENTS.md`. The deploy module's section carries the essentials in
  a few lines: the services and when each exists, `bin/deploy_env`,
  `.env.production` never committed and saved with each backup, logs in
  the `log` volume (`docker compose exec web tail log/<env>.log`), and
  `docs/guides/deploy-hetzner.md` in the monk repo for the host steps,
  as other modules' `SETUP.md` sections already point to Monk's guides.
- **The smoke test's generic checks go to `monk check`** (0.27), which
  then runs on the host as `docker compose run --rm web bin/check`.

**Built (2026-11-20):**

- **One mechanism, two more section kinds.** `compose_section` and
  `production_env_section` join `setup_section` and `agents_section`.
  When `compose.yaml` or `.env.production.example` exists, each module
  installed or being added appends its block, marked
  `# monk:module <name>`, so deploy added first or last gives the same
  files. `compose.yaml` keeps `services:` as its last key, so a block can
  be appended under it.
- **Which parts come from where.** `postgres`, `redis`, `jobs` and
  `websocket` add services; every module with settings adds its lines.
  The `Caddyfile` always routes `/ws*`: Caddy resolves upstreams per
  request, so without websocket nothing answers there, and a later
  websocket needs no edit.
- **`bin/deploy_env`, in bash.** It fills in whatever is empty:
  `AUTH_SECRET` and `STORAGE_SECRET` (`openssl rand -hex 32`), one
  password for `DB_PASSWORD` and `POSTGRES_PASSWORD`, and the VAPID pair
  via `monk push keys` in the built image. Then it lists what's still a
  placeholder. A second run changes nothing.
- **No `depends_on` on postgres.** `web` can't name a service that a
  later module adds, so the docs start Postgres first
  (`up -d --wait postgres`), and `restart: unless-stopped` covers a
  reboot.
- **Checked:**
  - the generator tests;
  - deploy in the module combinations test;
  - `docker compose config` on a generated app;
  - a full run on local Docker, with this branch's Monk vendored into a
    generated app (live, jobs, push, deploy): `bin/deploy_env` wrote the
    secrets and the VAPID pair, Postgres became healthy, `bin/setup_db`
    migrated, and all five services ran. https answered 200 with the
    security headers, http answered 308, and `/ws` answered 101. A job
    enqueued from `web` ran in `jobs` and logged to the shared volume.
- **The lockfile claim, checked.** Ruby 4's Bundler (4.0.16) locks every
  platform for a new lockfile. The first app's lockfile, from September,
  listed only `arm64-darwin`, and Bundler keeps an existing lockfile's
  list. `deploying.md` and the Dockerfile's comment now say so, with the
  `--add-platform` command.
- **Docs.** `docs/guides/deploy-hetzner.md` covers accounts, server,
  DNS, shipping, Brevo, checks, backups, costs and day-to-day work.
  `deploying.md` section 4 now points at `monk add deploy`. The deploy
  module's SETUP.md and AGENTS.md sections are added too.

**Later, not in 0.26:** `--provider hetzner` writing the scripts, once a
third app confirms their shape, with tests using a fake `hcloud` and
`ssh` on `PATH`. Adding a provider to an app already deployed would need
`monk add` to add what a new option value brings to an installed module.

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
   - Done. Form helpers and validation errors: patterns, not code
     (decision 16).
10. Done. C2: a stale CSRF cookie is reissued (decision 17).
11. Done. C1: the client says hidden on `pagehide` and `freeze`; a
    closed socket is away for the grace, not online (iPhone measured).
12. Done. C3: `monk add deploy`, `docs/guides/deploy-hetzner.md`, the
    deploy module's `SETUP.md` and `AGENTS.md` sections.

## Open

- C3: none for 0.26; `--provider` later.

Released with the CHANGELOG's 0.26 entry and the upgrade guide's 0.26
section (`docs/guides/upgrading.md`).
