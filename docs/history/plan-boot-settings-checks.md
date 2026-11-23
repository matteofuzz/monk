# 0.27: Refusing wrong settings at boot — plan

Drafted and built 2026-11-20, on `main_dev/v_0_27`. Roadmap item 6, first
bullet (`docs/roadmap.md`). All steps done; full suite 1532 runs, 0
failures, 0 skips.

## The problem

Boot already refuses a setting that's missing. It doesn't refuse one that's
present but wrong, and the wrong ones fail silently, the first time a real
person hits them:

- `PUBLIC_URL` left at the deploy template's `https://app.example.com`:
  every magic link points nowhere.
- `PUBLIC_URL` on `http://` in production: the session cookie is `Secure`
  outside development, so the browser never sends it back and nobody stays
  signed in.
- `PUBLIC_URL` with a trailing slash (`https://app.com/`): it's the default
  WebSocket origin list, compared exactly with the browser's `Origin`
  header, which never has one. Every signed-in socket is refused, and magic
  links get a double slash.
- `LIVE_WS_URL` on `ws://` while the page is on `https://`: the browser
  blocks it as mixed content. Live never connects.
- `AUTH_SECRET` left at a `change-me` placeholder, or short: sessions are
  signed with a key anyone can read in the template.
- `WS_ALLOWED_ORIGINS` set without `PUBLIC_URL` in it: the app's own pages
  are refused a signed-in socket.

## What exists

- `Monk::Settings.freeze_registry!` (`lib/monk/settings.rb:94`) raises on a
  missing required key, and validates `MONK_ENV` and `LOG_LEVEL`. Every
  process runs it at boot: the web server (`Base#freeze!`), `bin/jobs`
  (`jobs/runtime.rb:55`) and `bin/websocket_server`
  (`websocket/server.rb:167`).
- Modules refuse bad values in their own `configure`, outside development
  and test: `Monk::Mail` (no `MAIL_URL`), `Monk::Storage` (no URL or
  secret), `Monk::Push` (a VAPID pair that doesn't match, a contact on an
  unreachable host: `Push::UNREACHABLE_HOST`). **VAPID keys that don't
  match are already refused**, so they're out of this plan.
- `public_url` and `live_ws_url` are declared by the app (the
  `config/settings.rb` and `config/live.rb` templates), but Monk's own code
  reads them: `Monk::Auth.login_link`, `Monk::Live` helpers' meta tag.
- `WS_ALLOWED_ORIGINS` is read in the `bin/websocket_server` template,
  defaulting to `PUBLIC_URL`, and passed to `Server.new(allowed_origins:)`.

## Decisions

1. **Same posture as the rest of Monk:** refuse outside development and
   test (so staging and production), with a message naming the variable and
   the fix. A check that's wrong in every environment (a trailing slash)
   runs everywhere.
2. **`public_url` and `live_ws_url` are checked in
   `Settings.freeze_registry!`, when declared.** Monk's own code reads them,
   so Monk owns what they mean. One place, every process, no new API: no
   per-declaration validators.
   - `public_url`, everywhere: an origin only: `http(s)://host[:port]`, no
     path, query or trailing slash.
   - `public_url`, outside development and test: `https://`, on a host that
     isn't a placeholder: `example.com`/`.net`/`.org`, `*.example`, `*.test`,
     `*.invalid` (a `PLACEHOLDER_HOST` pattern in `Settings`). This catches
     the deploy template's `https://app.example.com` left as is.
     `localhost` and IP addresses pass: the deploy stack run locally with
     `MONK_ENV=production` and `PUBLIC_URL=https://localhost` is a real use
     (the `deploy` Caddyfile gets localhost a certificate from Caddy's local
     CA), because assets, `Secure` cookies, logging, mail and storage all
     behave differently outside development. `Push::UNREACHABLE_HOST` stays
     as it is: a push contact must be reachable by Apple, which is a
     stricter rule.
   - `live_ws_url`, outside development and test: `wss://`.
   - One new error class, `InvalidSettingError`, next to
     `InvalidMonkEnvError`.
3. **`AUTH_SECRET` is checked in `Monk::Auth.configure(secret:)`**, outside
   development and test: refused if it contains `change-me` (every
   template's placeholder) or is shorter than 32 characters. `bin/deploy_env`
   makes 64 (`openssl rand -hex 32`). `InvalidAuthConfigError`, like
   Auth's other configure checks.
4. **`WS_ALLOWED_ORIGINS` becomes the extra origins.** The
   `bin/websocket_server` template always allows `PUBLIC_URL`, plus any
   listed. This removes the failure instead of detecting it.
   `Server.new(allowed_origins:)` refuses an entry that isn't an origin
   (same rule as `public_url`), in every environment: it can never match.
5. **Left out:**
   - `STORAGE_SECRET`'s placeholder. It's only used with `file://` storage
     in production, which is rare, and `bin/deploy_env` fills it in.
   - `LIVE_WS_URL` on a different host than `PUBLIC_URL`. The session
     cookie won't reach it, but an app without auth on the socket can
     legitimately do it.
   - A way to skip the checks. A local production run uses
     `https://localhost` through Caddy; plain `http://` is refused, and the
     `Secure` cookie would break it anyway.

## Steps

1. **Settings.** `InvalidSettingError`, `PLACEHOLDER_HOST`, the
   `public_url` and `live_ws_url` checks. Tests in
   `test/settings_test.rb`: each wrong value refused with its message, each
   right one accepted, development and test unaffected.
2. **Auth.** The `AUTH_SECRET` check, tests in `test/auth_boot_test.rb`.
3. **WebSocket.** The origin check in `Server.new`, and the template's
   `allowed_origins` always including `PUBLIC_URL`. Test it in
   `test/generators/websocket_test.rb`.
4. **Existing tests that boot outside development and test.** None needed
   a change: `test/generators/base_test.rb:158` stubs `bundle`, so the app
   never boots, and `test/generators/live_test.rb:88` reads the setting
   before boot.
5. **Docs.**
   - `docs/guides/settings.md`: the checks and why, and one table of what
     each `MONK_ENV` changes (assets, cookies, logging, mail, auth
     delivery, storage, Redis, `LIVE_WS_URL`, the test-only helpers), so
     it's said once which modules treat test like development and which
     like production. Staging differs from production only in its log
     file.
   - `docs/guides/websocket.md` and the websocket templates (`setup.md`,
     `agents.md`, `deploy/env.production`): `WS_ALLOWED_ORIGINS` is the
     extra origins.
   - The `config/settings.rb` template's comment on `public_url`.
   - Running the stack locally in production mode, with
     `https://localhost`: in `settings.md`. `deploy-hetzner.md` §7 says
     boot refuses wrong values, instead of pointing at `monk check`.
   - `docs/guides/upgrading.md`, 0.27:
     - staging or production with a placeholder or `http://` `PUBLIC_URL`
       (CI included) now fails at boot;
     - drop `PUBLIC_URL` from `WS_ALLOWED_ORIGINS` (harmless if left);
     - an app's existing `bin/websocket_server` keeps the old behaviour until
       its line is changed by hand.
   - CHANGELOG.

## Settled

1. A short or placeholder `AUTH_SECRET` is refused, not warned about: the
   fix is one `openssl rand -hex 32`, and the upgrade guide says so.
2. `localhost` passes outside development (over `https://`), for the
   production stack run locally (decision 2).
