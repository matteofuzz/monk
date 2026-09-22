# Plan: deployment gaps found in monk_talk, and the Kino `X-Forwarded-*` check

Status: planned 2026-09-21, nothing implemented yet. Source: a list of gem
issues found while deploying `monk_talk`, plus a question about Kino's
handling of forwarded headers.

## 0. Kino `X-Forwarded-*` check (do first, since it shapes #1)

**Known so far**

- Kino 0.7.0's compiled binary contains the names `x-forwarded-for`, `-proto`,
  `-host`, `-port` and `x-real-ip`, plus `rack.url_scheme`. `strings` can't
  tell whether these are only interned header names or whether Kino acts on
  them.
- Kino's README says `HTTP_HOST`, `SERVER_NAME` and `SERVER_PORT` come from
  Host/`:authority`. Over a unix socket, `REMOTE_ADDR` is 127.0.0.1.
- Monk's `lib/` reads no `X-Forwarded-*` header. The one the app reads for the
  magic link lives in `monk_talk`.
- `Gemfile.lock` pins Kino 0.4.0. Versions 0.5.0 to 0.7.0 are also installed.

**Check**

1. Run a throwaway `config.ru` outside the repo that dumps the Rack env. Run
   it under Kino 0.4.0 (the pinned version) and 0.7.0.
2. Send spoofed `X-Forwarded-Proto`, `-For`, `-Host` and `-Port` from a direct
   client.
3. Record whether `rack.url_scheme`, `REMOTE_ADDR`, `HTTP_HOST` or
   `SERVER_PORT` change.
4. Read the `monk_talk` magic-link code to see whether it validates the header
   or takes it as-is. Then report.

**Outcome**

- Headers pass through untouched: Kino trusts nothing. Any trust logic belongs
  in the app or in Monk.
- `rack.url_scheme` follows the header: an untrusted client can spoof HTTPS.
  Then #1 must not derive Secure from the scheme, and this becomes a separate
  issue to flag upstream.

**Result (2026-09-21)**

- Kino 0.4.0 and 0.7.0 trust no `X-Forwarded-*`, `X-Real-IP` or `Forwarded`
  header. `rack.url_scheme`, `REMOTE_ADDR`, `HTTP_HOST`, `SERVER_NAME` and
  `SERVER_PORT` come from the real connection; the headers arrive only as raw
  `HTTP_*` entries. (The spike ran in `:threaded` fallback mode; Ractor mode
  shares the same compiled request-env code but wasn't tested.)
- Consequence for #1: Secure must come from an explicit setting, since
  `rack.url_scheme` is always `http` behind a TLS proxy.
- `monk_talk/config.ru:40` reads only `X-Forwarded-Proto`, and builds the link
  host from the raw `Host` header. Neither is checked against a trusted proxy.
  Harmless today (`log_dev_link` is development-only), but once a real mailer
  sends these links (#3), a direct client could get a login email with a
  poisoned scheme or host.
- **Decision:** the magic-link scheme and host must come from a configured
  public URL, never from request headers. This shapes #3 and #4.

## 1. Secure cookie always set (`lib/monk/auth/helpers.rb:56`)

- `docs/history/secure-cookie-dev-http.md` already documents the bug as "not
  yet fixed".
- Add a `secure:` option to `Monk::Auth.configure`, defaulting to true so
  production stays safe.
- Have the scaffold's development config set `secure: false`.
- Don't infer Secure from the request scheme unless step 0 shows Kino handles
  that safely.
- Tests: `Secure` present by default, absent when `secure: false`, and both
  cookies (session and CSRF) follow the option.
- Docs: a short note in the auth guide and a CHANGELOG entry.

## 2. App Dockerfile in the scaffold

- The repo's Dockerfile is for Monk itself, and the scaffold generates no
  Dockerfile for apps.
- Add `Dockerfile` and `.dockerignore` to `templates/base`. It would bind
  `0.0.0.0`, honor `PORT`, and start `bin/server`.
- `bin/websocket_server` is already in the base and live templates. The image
  should be able to run it as an alternate command.
- **Decision: one image, two commands, no supervisor.**
  `docs/guides/deploying.md` section 4 had already assumed this shape; the
  HTTP and WS processes are already separate deploy units by design
  (`docs/design/websocket.md`), so `docker run <image> bin/websocket_server`
  (or a compose `command:` override) is enough -- no process manager needed
  in the image.
- **Result (2026-09-22):** implemented. `templates/base/Dockerfile` +
  `.dockerignore` (unconditional), `templates/postgres/Dockerfile` overrides
  it with libpq for `--postgres`/`--auth`, wired via `scaffold.rb`'s
  `POSTGRES_OVERRIDES` (same mechanism as `LIVE_OVERRIDES`). Verified with a
  real `docker build`/`docker run` for both variants, not just file-copy
  tests. Along the way, fixed a port-collision bug in `deploying.md`'s own
  Fly.io Dockerfile snippet (hardcoded 9293, colliding with `WS_PORT`'s
  default) and updated deploying.md to point at the generated file instead
  of a hand-copied snippet.
- Tests: check that the scaffold output contains the files. Done --
  `test/scaffold_test.rb`.

## 3. Auth delivery hook (mailer)

- Add an app-supplied callable to `Monk::Auth.configure`, for example
  `deliver:`. It would receive the email, the link and the token.
- `docs/design/auth-sessions.md:321` deliberately keeps email delivery outside
  the framework, so Monk gets no SMTP or mailer dependency.
- `log_dev_link` stays as the development fallback.
- The link's scheme and host come from a configured public URL (the same
  setting as #4), never from `Host` or `X-Forwarded-*` request headers (see
  step 0).
- **Resolved:** Monk hands the app the token and the public URL, not the
  full link -- Monk doesn't own routing, so it can't know the callback
  path (`/auth/callback/:token` is the app's own route).
- The callable must be Ractor-shareable, which fits the existing
  freeze-at-boot rules.
- **Result (2026-09-22):** implemented. `Monk::Auth.configure(deliver:)` +
  `Monk::Auth.deliver_link(email:, link:, token:)`; falls back to
  `log_dev_link` in development, raises `Monk::MissingAuthDeliveryError`
  otherwise. `public_url` declared in `config/settings.rb` (moved there in
  #4, so `--live` apps get it too, not just `--auth`).
- Tests: the hook is called with the right arguments, and unconfigured
  behavior doesn't change. Done -- `test/auth_deliver_test.rb`,
  `test/auth_boot_test.rb` (Ractor-shareability, both directions).
- Docs: replace the "No mailer yet?" section with the hook as the production
  path. Done -- `docs/guides/auth.md` "Sending the magic link";
  `docs/design/auth-sessions.md`'s old section marked superseded, not
  rewritten (historical record).

## 4. Two-port WebSocket

- Sharing the HTTP port isn't possible: Kino deliberately omits hijack
  (`docs/design/websocket.md`). So this is docs and templates, not code in the
  socket layer.
- Add a reverse-proxy snippet (nginx or Caddy) to `deploying.md` that routes
  `/ws` to `:9293` under one public origin. **Already existed** (section 3)
  before this point was started -- written in a prior session/edit; nothing
  to add here, just wired PUBLIC_URL into its explanation.
- Derive `live_ws_url` and `WS_ALLOWED_ORIGINS` from a single public-URL
  setting, also used for the magic link in #3. Keep the localhost defaults for
  development.
- **Result (2026-09-22):** implemented. Moved `public_url` from
  `config/auth.rb` (#3) to `config/settings.rb` (every app, not just
  `--auth`). `live/config/live.rb`'s `live_ws_url` default: direct
  `ws://localhost:9293` in development (no proxy locally), else a
  `wss://`/`/ws` path under `public_url` -- matching section 3's existing
  proxy routing. Both `bin/websocket_server` templates default
  `WS_ALLOWED_ORIGINS` to `public_url` itself. Verified: dev vs production
  derivation, and `--auth --live` together don't double-declare
  `public_url` (`Monk::DuplicateSettingError`) -- confirmed by a real
  `require`-based boot of the generated files, not just template-content
  comparison.
- Tests: check the scaffolded config defaults. Done --
  `test/scaffold_live_test.rb` (4 new tests).

## Delivery

- All work goes on the current branch, `main_dev/better_support_for_deploy`.
  One branch for all four points, no per-point branches.
- Push the branch, but don't open a PR or merge (the maintainer does that
  manually).
- Order: 0, then 1, 3, 2, 4 -- **all four done** (2026-09-22).
