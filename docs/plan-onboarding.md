# Plan: a smoother first sign-in (0.28)

Status: planned 2026-11-24, from monk_talk's walk of its invitation and
sign-up flows on staging (monk_talk `doc/v0-4-8_implementation_plan.md`).
Nothing built yet.

## The problem

A magic link sends the person out of the page they're on: to the mail
app, then into whatever browser the mail app opens. On a phone that is
rarely the one they started in:

- **A page opened in a chat app's built-in browser** (WhatsApp,
  Instagram) loses everything it knew (a cookie, an invitation) when the
  link opens in Safari or Chrome.
- **The installed app on an iPhone can't receive a link at all:** Mail
  always opens it in Safari.
- **Sessions expire after `session_ttl` however much they're used**, and
  a push subscription stops with its session: someone who doesn't open
  the app for two weeks stops being notified, without being told.
- **iPhone, checked on iOS 26.6.2 (2026-11-24):** Add to Home Screen
  copies Safari's cookies into the app once, so the app starts signed
  in, but with *the same session*: logging out in either logs out both
  (and ends the app's notifications). Afterwards their cookies are
  separate: signing in again in Safari doesn't sign the app in.
- **Nothing helps a person install the app,** though on iOS web push
  needs it: each app writes its own banner, platform checks and
  instructions.
- **`redirect_allowlist` takes exact paths only:** a link can't return
  to a page with an id in its path (`/invite/<code>`).

## Decisions

### Auth: where a link returns, and what the mail knows

1. **`redirect_allowlist` takes patterns.** An entry is a String (an
   exact path) or a Regexp, which must match the whole path: Monk
   checks the match covers it, so a missing `\z` can't let a suffix
   through. Whatever the list says, a `redirect_to` starts with one `/`
   (never `//` or `/\`). The match is against the path only: a query
   string (`/invite/abc?x=1`) is allowed after a matching path, and kept.
   A Regexp is made shareable in `freeze_registry!` like the rest of the
   config.
2. **`Monk::Auth.allowed_redirect?(path)`**, the same check, public: a
   route tests it before enqueueing `SendLoginLink`, whose
   `InvalidRedirectError` would otherwise fail unseen in the job.
3. **`deliver:` always gets `redirect_to:` and `code:`** too, beside
   `email:, link:, token:`. No check of what the callable accepts: the
   scaffolded `AuthMailer::MAGIC_LINK` takes them, and the upgrading
   guide says to add them (or `**`) to an existing `deliver:`.
4. **`Monk::Auth.redirect_for(raw)`**: the `redirect_to` of a token
   that exists, expired or used, else nil. Only whoever holds the token
   learns it. A callback sends an expired link back where it was going
   (monk_talk's invitation page, with `?expired=1`).

### Auth: a sign-in code beside the link

5. **One login token, two ways to redeem it.** `request_login` also
   makes a 6-digit code (`SecureRandom`, zero-padded); the row keeps
   its HMAC (`code_hash`, keyed by the auth secret: six digits are
   trivial to try offline) and a failed-attempts count. Redeeming the
   link or the code uses the token: the other stops working. Same
   `login_ttl`. `request_login` returns `{ token:, code: }` (decided
   while building: explicit, one line in the upgrading guide).
6. **`Monk::Auth.redeem_code(email, code)`** → a session, like
   `redeem`, or nil. It checks the newest live token for that address,
   in constant time. The address is stripped and downcased, here and in
   `request_login`, so the two always agree. Asking for a new code makes
   the previous one stop working: only the newest token is checked. A wrong code counts an attempt; the fifth burns the
   token (`MAX_CODE_ATTEMPTS`). Since a new code can be asked for every
   `login_request_interval`, failed attempts are also counted per
   address, on its `login_requests` row: past `MAX_CODE_FAILURES_PER_HOUR`
   (10), `redeem_code` returns nil for that address until the hour is
   up. This protects the code itself; rate limiting by IP stays the
   app's.
7. **The scaffold:** the waiting page ("Check your email") becomes the
   code form (`inputmode="numeric"`, `autocomplete="one-time-code"`,
   "Wrong address?", "Send a new code"); `POST /auth/code` redeems it
   and redirects to the token's `redirect_to`. The scaffolded mail's
   subject starts with the code (`"482913 is your <app> code"`), so a
   phone's notification shows it, and Safari can fill it in.

### Sessions that last while they're used

8. **Renewed by use.** When a request's session has less than half of
   `session_ttl` left, `current_subject` moves its `expires_at` to now
   + `session_ttl` and reissues both cookies: one `UPDATE` per session
   per half TTL, never per request. The `UPDATE` is conditional
   (`WHERE id = $1 AND expires_at < $2`), so two requests arriving
   together write once. A Bearer request renews the row too (no cookies
   to reissue). `session_max_age:` (default nil, no cap) can cap a
   session's whole life, from the existing `sessions.created_at`: no
   migration. Only HTTP requests renew; the WebSocket's check doesn't
   write.
9. **The installed iPhone app gets its own session.** `POST
   /auth/own` (scaffolded): for a valid session, a new one for the same
   subject, cookies set; the old one is left to Safari.
   `Monk::Auth.split(raw)` does it. The PWA client calls it once, on
   the first launch with `navigator.standalone === true` (iOS only:
   Android's app shares Chrome's cookies), and remembers it in
   `localStorage` only once it succeeded, so a first launch offline
   tries again next time. The route checks `require_csrf!`. `push.js`
   waits for it before subscribing, so the app's subscription belongs to
   the app's session, not Safari's. A logout or expiry in one no longer
   reaches the other.

### Push that outlives an idle session

10. **Auth keeps expired sessions for a while:
    `Monk::Auth.configure(expired_retention:)`** (seconds, 90 days by
    default). `sweep!` deletes a session only once it has been expired
    that long. Push's `LIVE` reads the same setting: a subscription
    counts until its session is revoked, or expired for longer than
    `expired_retention`. Logging out still stops it at once; an idle
    person keeps being notified (notifications carry no secret: the app
    decides what they say). The subscription's `ON DELETE CASCADE`
    stays; `subscribed(subjects)` follows the same rule.

### PWA: helping people install

11. **The client says what's possible:** `register.js` sets, on
    `<html>`, `data-pwa-standalone`, `data-pwa-platform` (`ios`,
    `android`, `other`), `data-pwa-installable` (Chrome's
    `beforeinstallprompt` was caught) and `data-pwa-in-app` (a built-in
    browser, guessed from the user agent: Instagram, Facebook, LinkedIn,
    Line, TikTok, Telegram; WhatsApp on iOS is undetectable). CSS can
    show the right thing with no JS of the app's own; `monk-pwa:installable`
    and `monk-pwa:installed` fire too.
12. **`<%= monk_install %>`**, a helper rendering the banner, its
    iOS sheet (a `<dialog>`: Share → Add to Home Screen, with the icons)
    and its button (`[data-monk-install]`: Chrome's prompt where
    installable). Text overridable (`monk_install(text: ...)`), markup
    with BEM classes and no styles: the app styles it. Hidden when
    standalone or on desktop (`other`, by default).
13. **"Open in your browser" is a documented pattern, not a helper.**
    With the code (5), a person signs in inside a chat app's built-in
    browser, so leaving it only matters for installing. Monk sets
    `data-pwa-in-app` (11); `docs/guides/pwa.md` shows how an app can
    add the button itself: Android's `intent://…#Intent;scheme=https;end`
    URL, iOS's `x-safari-https://…` (undocumented, blocked by some apps)
    with "Tap ••• → Open in Safari" as the fallback, and that WhatsApp
    on iOS can't be detected.

## Steps

One commit per step, red → green, against the test Postgres; the
browser parts in headless Chrome like the other client tests.

1. **Redirects and the mail's context** (decisions 1-4).
2. **The code** (5-7): migration (`login_tokens.code_hash`,
   `code_attempts`, an index on `(email, created_at)`;
   `login_requests.code_failures`, `code_failures_since`),
   `redeem_code`, the scaffold's route, page and mail.
3. **Renewal** (8): `current_subject`, `session_max_age:`.
4. **The installed app's own session** (9): `split`, the route, the
   client call.
5. **Push after expiry** (10): `expired_retention:`, `sweep!`,
   `Store::LIVE`, `subscribed`.
6. **Installing** (11-12): `register.js`, `monk_install`, its test page.
7. **Release 0.28:** `docs/guides/auth.md`, `pwa.md` (with the "Open
   in your browser" pattern, 13), `push.md`;
   `templates/auth/agents.md` and `setup.md`; the upgrading guide (the
   migration, the scaffold's new route and page, `deliver:`'s new
   keywords, `monk_install` in the layout); CHANGELOG; roadmap.

## Open checks (on devices, with monk_talk on staging)

- The code filled in by Safari from Mail (iPhone), typed on Android.
- Signing in with the code inside WhatsApp's and Instagram's built-in
  browsers. For the documented pattern: `x-safari-https://` from those
  and Telegram's on iOS; the intent URL from the same on Android.
- The iPhone app's own session: log out in Safari, the app stays signed
  in and notified.
- A session renewed by use; a subscription still notified after its
  session expired (shortened TTLs on staging).
