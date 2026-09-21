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
- Open decision: one image with two commands (simplest, one deploy unit per
  process) or a supervisor.
- Update `docs/guides/deploying.md` to match.
- Tests: check that the scaffold output contains the files.

## 3. Auth delivery hook (mailer)

- Add an app-supplied callable to `Monk::Auth.configure`, for example
  `deliver:`. It would receive the email, the link and the token.
- `docs/design/auth-sessions.md:321` deliberately keeps email delivery outside
  the framework, so Monk gets no SMTP or mailer dependency.
- `log_dev_link` stays as the development fallback.
- The link's scheme and host come from a configured public URL (the same
  setting as #4), never from `Host` or `X-Forwarded-*` request headers (see
  step 0). Open question: does Monk build the full link, or hand the app the
  token and the public URL?
- The callable must be Ractor-shareable, which fits the existing
  freeze-at-boot rules.
- Tests: the hook is called with the right arguments, and unconfigured
  behavior doesn't change.
- Docs: replace the "No mailer yet?" section with the hook as the production
  path.

## 4. Two-port WebSocket

- Sharing the HTTP port isn't possible: Kino deliberately omits hijack
  (`docs/design/websocket.md`). So this is docs and templates, not code in the
  socket layer.
- Add a reverse-proxy snippet (nginx or Caddy) to `deploying.md` that routes
  `/ws` to `:9293` under one public origin.
- Derive `live_ws_url` and `WS_ALLOWED_ORIGINS` from a single public-URL
  setting, also used for the magic link in #3. Keep the localhost defaults for
  development.
- Tests: check the scaffolded config defaults.

## Delivery

- All work goes on the current branch, `main_dev/better_support_for_deploy`.
  One branch for all four points, no per-point branches.
- Push the branch, but don't open a PR or merge (the maintainer does that
  manually).
- Order: 0, then 1, 3, 2, 4.
- Open questions:
  1. Run the step 0 spike now?
  2. For point 2, one image with two commands, or a supervisor?
