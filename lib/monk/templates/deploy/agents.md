## deploy

**Where:** `compose.yaml` (services: `web`, `caddy`; `ws` with websocket,
`jobs` with jobs, `postgres`, `redis` with theirs), `Caddyfile` (`/ws*`
to `ws:9293`, the rest to `web:9292`), `.env.production.example`,
`bin/deploy_env`. A module added later appends its services and settings
(`# monk:module <name>` blocks).

**On the host:** `bin/deploy_env` (writes `.env.production`, fills in
empty secrets), `docker compose build`, `docker compose up -d --wait
postgres`, `docker compose run --rm web bin/setup_db`, `docker compose up
-d`. Step by step on Hetzner with Brevo: `docs/guides/deploy-hetzner.md`
in the monk repo.

**Pitfalls:**
- Never commit `.env.production`, never put a secret in the example, and
  keep `services:` the last key of `compose.yaml` (modules append there).
- `.env.production` goes with every database backup: its `AUTH_SECRET`,
  VAPID pair and the app's own keys are what the data was written with.
- `.env.production` lines are `KEY=value`, no comment after a value.
- Logs are in the `log` volume (`docker compose exec web tail -f
  log/<MONK_ENV>.log`), not `docker compose logs`.
- `web`'s health check, and Caddy's, call `GET /_monk/up` (204, no
  database): a check of the database is a route of its own, never that one.
- `Gemfile.lock` must list the host's platform (`x86_64-linux` or
  `aarch64-linux`); `monkrb` from a `path:` can't build in the image.
