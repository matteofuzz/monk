# 0.25: PWA and web push — plan

Drafted 2026-11-13, analysis only: nothing is built yet. Roadmap item 4
(`docs/roadmap.md`). Two Monk modules, shipped together because on iOS
web push only reaches an app installed on the Home Screen (16.4+):

- **A. `monk add pwa`.** A web app manifest, icons, and a `sw.js` served
  at the root scope, without getting in the way of the Live client.
- **B. `monk add push`, `Monk::Push`.** VAPID keys, storing
  subscriptions, sending from a job, and deleting subscriptions the push
  service reports as gone (404/410).

A comes first: B's service worker handlers live in A's `sw.js`.

## What exists today

- **Static files.** `Monk::Assets` serves `public/` from a manifest
  frozen at Boot, plus gem directories mounted under `/_monk/...`
  (`Assets.mount`; Live's client is served from `/_monk/live`). In
  production a file linked without `?v=` is served
  `public, max-age=0, must-revalidate`. `TEXT_TYPES` has no
  `.webmanifest`.
- **Head tags.** The layout's `<%= monk_head %>` renders `head_tags`, which
  each module's helpers extend with `def head_tags = super + [...]`
  (`Monk::Live::Helpers`).
- **Sending from a job.** `Monk::Mail.deliver_later` and
  `Mail::DeliveryJob`: input checked in the caller before enqueueing,
  `never_retry` for final errors, `conn:` to enqueue inside the caller's
  transaction.
- **Outgoing HTTPS with hand-written signing, no gem.**
  `Storage::Backends::S3` (Net::HTTP) and `Storage::SigV4` (OpenSSL HMAC).
  Neither uses `OpenSSL::PKey`, so EC keys inside a Ractor are untested.
- **Auth sessions.** `sessions (id, subject, token_hash, expires_at,
  revoked_at)`. `revoke`/`revoke_all` set `revoked_at` and don't delete
  the row; `sweep!` deletes expired rows (nightly, `Monk::Auth::Sweep`).
  `Auth::Helpers#session_cookie_token` gives the request's raw token.
- **Generators.** `env` values may be blocks taking the app's name, so a
  key pair can be generated when the module is added. `copy` reads with
  `binread`, so binary icons copy fine. `{{app}}` is replaced only in
  `setup.md`/`agents.md` sections (`Generator::Run#section_entries`), never
  in copied files. Migrations go up to `00000000000005` (presence).
- **What the first app needs** (monk_talk, V0.3): installable app, web
  push, a "Reachable" status next to presence, a Notifications switch, and
  handling of revoked permissions and expired subscriptions.

## Decisions

1. **A subscription belongs to an auth session, not only to a subject.**
   Notifications go to the devices where a person is signed in. A shared
   device whose user logged out stops receiving that person's
   notifications, even if the logout never reached the server from that
   device. Hence `monk add push` depends on `auth`; see B3.
2. **Two modules.** `pwa` alone makes an app installable; `push` depends
   on `pwa` (its handlers live in `sw.js`), `jobs` and `auth`.
3. **`copy` can fill in the app's name.** A `copy` flag, opt-in per file,
   replaces `{{app}}` with the app's name, so the manifest's `name` works
   on the first install instead of shipping "Monk app" when a todo is
   skipped. Existing `copy` lines don't set it, so no existing template's
   output changes (none contains `{{`). See A2.
4. **Encryption and VAPID written by hand, no gem**, as SigV4 was: RFC
   8291 (`aes128gcm`) and RFC 8292 over OpenSSL. The `webpush` gem is
   barely maintained and was never checked under Ractors. Recorded in ADR
   0020.
5. **One delivery job per subscription**, so a retry resends only to the
   device that failed, and a 404/410 deletes exactly that row.
6. **`sw.js` has no `fetch` handler.** No offline caching in 0.25: it
   can't intercept Live's resync refetch, auth redirects, signed storage
   links or CSRF-protected POSTs. Chrome no longer requires one to
   install.
7. **The browser side is declarative, like Live**: `data-push-*`
   attributes and `monk-push:*` DOM events, no JS API.
8. **The client re-sends its subscription on every page load** (when
   permission is granted). That's how rotated endpoints and server-side
   deletions heal; `pushsubscriptionchange` is unevenly supported and a
   service worker has no CSRF token.

## Part A: PWA (`monk add pwa`)

### A1. Serving

- `Assets::TEXT_TYPES`: `.webmanifest` → `application/manifest+json`.
- `sw.js` is the app's own file, `public/sw.js`: a service worker's scope
  is capped at its own path, so it can't be served from `/_monk/`, and the
  app edits it (what a notification click opens).
- Registered as plain `/sw.js`, never through `asset_path`: a `?v=`
  digest would give the worker a new URL on every deploy, and a new URL is
  a different registration. A test pins that `/sw.js` is served
  `must-revalidate` in production.

### A2. Generator

```ruby
Monk::Generator.define(:pwa) do
  summary "Installable app: web app manifest, icons, service worker"
  installed_if "config/pwa.rb"
  copy "config/pwa.rb", "public/sw.js", role: :wiring
  copy "public/manifest.webmanifest", role: :wiring, app_name: true
  copy "public/icons/icon-192.png", "public/icons/icon-512.png",
    "public/icons/icon-maskable-512.png", "public/icons/apple-touch-icon.png", role: :wiring
  copy "test/pwa_test.rb", role: :test
  ...
end
```

- `manifest.webmanifest`: `name`/`short_name` `"{{app}}"`, `start_url "/"`,
  `display "standalone"`, `theme_color`, `background_color`, the icons.
  A todo: "set a display name in name/short_name, and replace the icons".
- `config/pwa.rb`: `require "monk/pwa"` and `Monk::Pwa.configure`, which
  checks the manifest and takes `theme_color` from it (step 3).
- **The `app_name:` flag** (decision 3), three places:
  - `Definition#copy` accepts `app_name: false`;
  - `Run#copy_entry` replaces `{{app}}` before comparing, so an unchanged
    file is still "same" on a re-run (a renamed app directory makes it a
    conflict: reported, never overwritten);
  - `CLI#file_help` (`monk help pwa --file ...`) replaces it for flagged
    files only: with the current directory's name inside an app, left as
    `{{app}}` outside one.

  Every other file is copied and printed exactly as today; the existing
  tests in `test/generator_test.rb` and `test/exe_monk_test.rb` cover
  that.

### A3. Head tags

`Monk::Pwa::Helpers#head_tags`: `<link rel="manifest">`,
`<meta name="theme-color">`, `<link rel="apple-touch-icon">`, the
`apple-mobile-web-app-*` metas, and
`<script type="module" src="/_monk/pwa/register.js">`, which registers
`/sw.js` (`Assets.mount("/_monk/pwa", ...)`). The layout doesn't change.

### A4. Staying out of Live's way

No `fetch` handler (decision 6); service workers never see WebSockets.
Device checks: in a standalone app on iOS and Android, Live reconnects and
resyncs when the app returns to the foreground (0.24's
`visibilitychange`/`pageshow` handling, never tried in standalone).

## Part B: Web push (`Monk::Push`, `monk add push`)

`require "monk/push"`, opt-in. Depends on `pwa`, `jobs`, `auth`.

### B1. Keys and configuration

```ruby
Monk::Push.configure(db_name: :primary, public_key: ENV["VAPID_PUBLIC_KEY"],
                     private_key: ENV["VAPID_PRIVATE_KEY"], contact: ENV["VAPID_CONTACT"])
```

- Keys are base64url raw P-256 values (the public one is what the browser
  takes as `applicationServerKey`).
- Boot fails when the private key doesn't derive the public one, or when
  `contact` isn't `mailto:` or `https:` (the JWT `sub`, which Apple
  requires).
- `Monk::Push.generate_keys` and `monk push keys`, which prints a pair for
  production.
- Generator: `env :development` and `env :test` get freshly generated
  pairs (a block); `.env.example` commented lines; `set_before_production`
  for `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_CONTACT`. The guide
  says that changing keys invalidates every subscription.

### B2. Crypto

- RFC 8291: an ephemeral ECDH key per message, HKDF
  (`OpenSSL::KDF.hkdf`), AES-128-GCM, RFC 8188 `aes128gcm` header, one
  record.
- RFC 8292: an ES256 JWT (`aud` the endpoint's origin, `exp` at most 12 h,
  `sub` the contact). The DER signature is converted to raw `r‖s`.
  `Authorization: vapid t=<jwt>, k=<public key>`. Signed per send: no
  cache (a Ractor can't memoize, and signing is cheap).
- On OpenSSL 3 keys are immutable: a key from raw bytes is built from DER
  (SubjectPublicKeyInfo; ECPrivateKey).
- **Spike** (step 1, done 2026-11-13, Ruby 4.0.6, openssl gem 4.0.2,
  OpenSSL 3.5.9): everything above works in a non-main Ractor, and gives
  the same result as in the main one. RFC 8291 Appendix A's body is
  reproduced byte for byte, a key rebuilt from its raw private scalar
  derives the right public key, and an ES256 JWT built as above verifies.
  8 Ractors × 200 rounds in parallel: no errors, 0.3 s. Findings:
  - a raw private scalar becomes a key through an ECPrivateKey DER built
    with `OpenSSL::ASN1` (its public point from
    `group.generator.mul(d)`); a raw public point through the fixed
    SubjectPublicKeyInfo prefix and `OpenSSL::PKey.read`;
  - `OpenSSL::PKey::EC` objects can't be made shareable
    (`Ractor::Error`), so `configure` keeps the keys as frozen raw
    Strings, and each send rebuilds the key it needs (cheap);
  - base64url via `pack("m0")`, as `Storage::Token` does, not the
    `base64` gem.
- Tests: RFC 8291 Appendix A's vector, with its fixed keys and salt.

### B3. Subscriptions

Migration `00000000000006_create_push_tables`:

```sql
CREATE TABLE push_subscriptions (
  id BIGSERIAL PRIMARY KEY,
  session_id BIGINT NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
  subject TEXT NOT NULL,
  endpoint TEXT NOT NULL UNIQUE,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  user_agent TEXT,
  expires_at TIMESTAMPTZ,
  last_success_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ON push_subscriptions (subject);
CREATE INDEX ON push_subscriptions (session_id);
```

- `subscribe(session_token:, subscription:, user_agent: nil)`: looks up
  the session (valid, not revoked) by the token's hash, takes its subject,
  upserts on `endpoint`. A device that signs in as someone else moves to
  them.
- Tied to the session (decision 1):
  - an expired session is deleted by `Auth.sweep!`, and its subscriptions
    with it (`ON DELETE CASCADE`);
  - a revoked session keeps its row, so `notify` only picks subscriptions
    whose session has `revoked_at IS NULL AND expires_at > now()`, and the
    job checks again before sending;
  - `Monk::Push::Sweep` deletes subscriptions of revoked sessions, and
    those past `expires_at`.
- `unsubscribe(endpoint)`, `subscriptions(subject)`.
- `subscribed?(subjects)`: for a batch of people, in one query, the ones
  with at least one live subscription. This is monk_talk's "Reachable",
  shaped like `Presence.status`.

### B4. Sending

- `Monk::Push.notify(subject, payload, ttl:, urgency:, topic:, conn:)`
  enqueues one `Monk::Push::DeliveryJob` per live subscription (decision
  5). `payload` is a JSON-able Hash, checked in the caller: too large for
  4096 bytes once encrypted raises there, as Mail does with bad input.
- `Monk::Push.deliver(subscription, payload, ...)`: sends now.
- How the push service's answer is handled:

  | Answer | Action |
  |---|---|
  | 201/202 | set `last_success_at` |
  | 404/410 | delete the subscription; the job succeeds |
  | 400, 413 | final error (`never_retry`) |
  | 401/403 | final, logged as an error: wrong VAPID keys or contact (Apple's `BadJwtToken`) |
  | 429, 5xx, network | retried with the jobs' backoff |

  `Retry-After` is honoured only if the jobs API already allows a retry
  delay per error; this release doesn't extend it.
- One log line per send, with the endpoint's host only: an endpoint is a
  credential.

### B5. Browser (`/_monk/push/push.js`, added to `head_tags`)

- `<button data-push-enable>` / `<button data-push-disable>`: a user
  gesture, which iOS requires to ask for permission.
- Metas from `head_tags`: the subscribe URL and the VAPID public key; the
  existing CSRF meta is reused.
- `monk-push:state` events: `unsupported`, `needs-install` (iOS in a
  browser tab rather than standalone), `default`, `denied`, `subscribed`.
- On every load with permission granted: `getSubscription()` and POST it
  (decision 8).
- Pure logic (state from capabilities and permission) in a separate file
  tested under Node, like `live/client/protocol.js`.

### B6. `sw.js` handlers (added to A's `sw.js` template)

- `push`: always `showNotification(title, { body, tag, data: { url } })`.
  iOS and Chrome penalise a push that shows nothing; the guide says so.
- `notificationclick`: focus an open window on `data.url`, or open one.
- `{title, body, url, tag}` is the scaffold's convention between the
  example and `sw.js`, not enforced by Monk.

Since `pwa` is copied first, `monk add push` can't rewrite `sw.js`. The
push handlers are therefore in `pwa`'s `sw.js` from the start, between
`// monk:example push-handlers` markers, commented out, with a todo from
`monk add push` to uncomment them. Step 3 left this to step 8: example
markers are found by `#\s*monk:example` (`Run#example_tags`,
`uncomment_examples`), which a JavaScript file would need as
`// # monk:example push-handlers`, or the regex extended to `//`.

### B7. Generator

`config/push.rb` (wiring), the migration, `test/push_test.rb`, and
examples:

- `push-subscribe`: POST and DELETE routes with `require_user!`,
  `require_csrf!`, `session_cookie_token`;
- `push-notify`: a call from a route or a job;
- `push-settings`: a partial with the enable and disable buttons;
- `push-sweep`: `Monk::Push::Sweep` nightly in `config/recurring.rb`.

`setup.md` (HTTPS everywhere but localhost; trying it on iOS) and
`agents.md`.

## Steps

Branches `main_dev/pwa` then `main_dev/push`, each merged into
`main_dev/0_25_0` by a PR.

1. Spike: OpenSSL EC, HKDF and GCM inside a Ractor. Done (B2).
2. The `app_name:` flag on `copy` and in `monk help --file`, with tests.
   Done: `Generator.fill_app_name` (also used for sections now), tests in
   `test/generator_test.rb` and `test/exe_monk_test.rb`.
3. A1-A3 with tests; A4 on desktop, Android, iOS. Done, except the
   device checks (step 10):
   - `Monk::Pwa.configure` checks the manifest the way Chrome does
     (`Pwa::Manifest.check!`): JSON, `name`/`short_name` without `{{app}}`,
     `start_url`, an installable `display`, a 192 and a 512 icon for
     purpose any, every local icon, `sw.js` and the apple-touch-icon on
     disk. It reads them under `Monk::Assets.root` (`public`), or `root:`.
   - `theme_color` comes from the manifest, so it isn't set twice; there
     is no `theme_color:` argument.
   - The icons are `role: :view`: an app's own icon is kept and reported
     skipped, not a conflict.
   - `test/pwa_browser_test.rb` runs a generated app's `bin/server` in
     headless Chrome: `/sw.js` registers with scope `/`,
     `Page.getInstallabilityErrors` is empty, and a controlled page still
     fetches from the app. It needs Chrome's default profile: in a Ferrum
     context (incognito) Chrome reports only `in-incognito` and skips the
     manifest checks.
4. B2 against the RFC vectors. Done: `Push::Keys`, `Push::Encryption`
   (`MAX_PAYLOAD` 3993 bytes: a full record is exactly 4096),
   `Push::Vapid`, `Push::Base64Url`; `test/push_crypto_test.rb` checks
   RFC 8291's body byte for byte, decrypts as a browser would (random
   salts and keys round-trip), verifies the JWT, and runs it all in 4
   worker Ractors. A private scalar outside `1...order` is refused.
5. B1: configure, key checks, `monk push keys`. Done: a missing key, a
   private key that isn't the public key's (checked by deriving it) and a
   contact that isn't `mailto:`/`https:` fail the boot; `monk push keys`
   prints the two env lines, or `--json`.
6. B3: migration, subscription API, session tie-in. Done:
   `Push::Subscription` (the browser's JSON, checked: https endpoint, or
   http on loopback for tests), `Push::Store`; `subscribe` stores a row
   only for a valid session (nil otherwise) and moves an endpoint to
   whoever subscribes it last; `subscribed(subjects)` returns
   `{ subject => bool }` (`subscribed?` for one). `Monk::Auth.token_hash`
   is public now, so Push finds the cookie's session in its own SQL;
   `monk/push` requires `monk/auth`.
7. B4: delivery job, against a fake push server in the tests (201, 404,
   410, 413, 429, 5xx).
8. B5-B6: browser side, Node tests for its logic.
9. B7: generator; the examples uncommented and run by Monk's tests.
10. Devices: Chrome, Firefox, macOS Safari, Android Chrome, iOS 16.4+
    Home Screen app. Enable, receive, open from a notification, permission
    revoked in settings, app reinstalled (a 410), logout on one device.
11. Docs: ADR 0020; `docs/guides/pwa.md`, `docs/guides/push.md`; CONTEXT.md
    (Push subscription, VAPID keys, Notification payload); the 0.25
    section of `docs/guides/upgrading.md`; CHANGELOG; roadmap entry Done.

Suite with 0 skips, with the Postgres, Redis and S3 containers up.

## Left for 0.26

`monk check` checks the VAPID keys and contact on a deployed environment
(the boot check of B1 already catches a mismatched pair).

## Open

- Device checks (A4, step 10).
- How `sw.js` gets the push handlers (B6): decided in step 8.
