# Deploying a Monk app

Example deployment cases for an app scaffolded with `monk new --postgres`
(`Gemfile`, `config.ru`, `config/persistence.rb`, `bin/setup_db`,
`bin/migrate`, `bin/console`, `db/migrate/`). Both cases below assume that
scaffold as the starting point.

Neither case changes anything in this repo (`monk` itself) — they describe
how a generated app deploys.

## What each scaffold needs

`monk new` flags combine along two independent axes — database (none,
`--postgres`, `--auth`, which implies `--postgres`) and Redis (none,
`--redis`, `--live`, which implies `--redis`) — so there are nine valid
combinations. `bin/websocket_server` is scaffolded in every one, but you
only run it if the app actually uses WebSockets; `--live` is the exception,
where it is mandatory.

| # | Command | `bin/server` | `bin/websocket_server` | One-off job | Postgres | Redis | Env vars | Extra gems |
|---|---|---|---|---|---|---|---|---|
| 1 | `monk new app` | required | only if the app uses WebSockets | none | no | no | none | none |
| 2 | `--postgres` | required | only if the app uses WebSockets | `bin/setup_db` | yes | no | `DB_*` | `pg`, `dotenv` |
| 3 | `--auth` (implies `--postgres`) | required | only if the app uses WebSockets | `bin/setup_db` | yes | no | `DB_*`, `AUTH_SECRET` | `pg`, `dotenv` |
| 4 | `--redis` | required | only if the app uses WebSockets | none | no | only if the WebSocket process runs | `REDIS_URL` | `redis`, `dotenv` |
| 5 | `--postgres --redis` | required | only if the app uses WebSockets | `bin/setup_db` | yes | only if the WebSocket process runs | `DB_*`, `REDIS_URL` | `pg`, `redis`, `dotenv` |
| 6 | `--auth --redis` | required | only if the app uses WebSockets | `bin/setup_db` | yes | only if the WebSocket process runs | `DB_*`, `AUTH_SECRET`, `REDIS_URL` | `pg`, `redis`, `dotenv` |
| 7 | `--live` | required | **required** | none | no | required | `REDIS_URL` | `redis`, `dotenv` |
| 8 | `--postgres --live` | required | **required** | `bin/setup_db` | yes | required | `DB_*`, `REDIS_URL` | `pg`, `redis`, `dotenv` |
| 9 | `--auth --live` | required | **required** | `bin/setup_db` | yes | required | `DB_*`, `AUTH_SECRET`, `REDIS_URL` | `pg`, `redis`, `dotenv` |

When the WebSocket process runs:

- It is its own deploy unit: its own port and public URL, and
  `WS_ALLOWED_ORIGINS` must match the app's origin.
- With `--auth`, connections must present a valid session; without it they
  are anonymous.
- With `--redis` but not `--live`, Redis only matters once you run more than
  one WebSocket instance (the `:chat` channel then fans out through it).
  With `--live`, Redis is the link between the app and the WebSocket
  process, and the app raises at boot without `REDIS_URL`.

The rest of this page walks through deploying case 2 (`--postgres`) on Render
and Fly.io; adding the WebSocket process is covered in section 3, and a
single-server alternative in section 4.

## 1. Render (native Ruby buildpack + managed Postgres)

**Local setup**

```
monk new my_app --postgres
cd my_app && bundle install
```

**Render resources**

1. **New PostgreSQL** — create it first; note the Hostname, Port, Database,
   Username, Password shown on the instance's Info page (internal
   connection, same region as the web service).
2. **New Web Service**, pointed at the repo:
   - Environment: `Ruby`
   - Build command: `bundle install`
   - Start command: `bundle exec kino -p "$PORT" --bind 0.0.0.0 config.ru`
     (Render injects `PORT`; Kino needs `--bind 0.0.0.0` to be reachable —
     it defaults to localhost)
   - Env vars: `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` —
     filled in from the Postgres instance's Info page. `config/persistence.rb`
     reads exactly these five vars, not a `DATABASE_URL`.

**Migrations**

Render web services don't run one-off pre-deploy commands by default, so
run `bin/setup_db` (which calls `Migrator#migrate!`) as a Render **Job**
against the same Postgres instance — manually per deploy, or wired to a
Deploy Hook. `bin/setup_db` is idempotent (applied versions are tracked in
`schema_migrations`), so re-running it is safe.

**Caveat**: this repo's own `Dockerfile` is not reusable as-is for a
scaffolded app — it bakes in *this* repo's gemspec/git-based install path
(`monk.gemspec` shells out to `git ls-files`), not a generated app's plain
`Gemfile`. That only matters if you deploy via Docker instead of Render's
native Ruby buildpack — see the Fly.io case below for a from-scratch
Dockerfile.

## 2. Fly.io (Docker + managed Postgres)

**Dockerfile** (no `git` runtime dependency needed, since a scaffolded
app's `Gemfile` pulls in `monk` as a normal gem, not via the local
gemspec):

```dockerfile
FROM ruby:4.0-slim AS builder
WORKDIR /app

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock* ./
RUN bundle install

FROM ruby:4.0-slim
WORKDIR /app

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends libpq5 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY . .

EXPOSE 9293
CMD ["bundle", "exec", "kino", "-p", "9293", "--bind", "0.0.0.0", "config.ru"]
```

(`libpq-dev` is needed at build time for the `pg` gem's native extension;
`libpq5` — the runtime lib, no headers — is enough in the final stage.)

**Fly resources**

1. `fly launch` in the app directory — detects the Dockerfile and creates
   the app.
2. `fly postgres create` to provision a Postgres cluster, then
   `fly postgres attach` to attach it to the app. This injects a
   `DATABASE_URL` secret automatically — but `config/persistence.rb` (from
   the scaffold) expects five discrete `DB_*` vars, not a URL, so either:
   - parse `DATABASE_URL` into the five vars inside `config/persistence.rb`
     (e.g. with `URI.parse`), or
   - skip `fly postgres attach` and set the five vars manually with
     `fly secrets set DB_HOST=... DB_PORT=... DB_USER=... DB_PASSWORD=... DB_NAME=...`
     using the connection details `fly postgres create` prints.
3. `fly deploy`.

**Migrations**

Run once per deploy, against the attached Postgres, via a one-off machine:

```
fly ssh console -C "bin/setup_db"
```

or wire it into a release step if the app's Fly config defines one.

## 3. Adding `Monk::WebSocket` alongside either case

`Monk::WebSocket::Server` is its own process on its own port
(`docs/history/plan-websocket.md` Decision 1) — it never shares a port with Kino, and a
reverse proxy in front routes by path: `/ws` to the WebSocket process,
everything else to Kino. This has to be **path-based routing on the same
host**, not a separate subdomain, unless the session cookie is explicitly
given `Domain=<shared parent domain>` — the browser session cookie rides
along on the WS handshake automatically only because cookies aren't
port-scoped *within the same host* (`docs/design/websocket.md`'s "Identity
crosses the process boundary"). Documented here, not generated by `monk
new` (Decision 8) — proxy config varies more by host than the Ruby side of
this feature does.

**Caddy** (shown here since it needs no separate config-reload step and
the whole routing rule fits in a few lines):

```caddyfile
example.com {
    reverse_proxy /ws* localhost:9293
    reverse_proxy localhost:9292
}
```

The equivalent **nginx** (the `Upgrade`/`Connection` headers below are
what actually let the connection upgrade — nginx doesn't forward them by
default):

```nginx
server {
    listen 443 ssl;
    server_name example.com;

    location /ws {
        proxy_pass http://127.0.0.1:9293;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }

    location / {
        proxy_pass http://127.0.0.1:9292;
    }
}
```

Both processes bind `127.0.0.1`/`localhost` — only the proxy is
internet-facing — and TLS terminates at the proxy either way; neither
Monk process ever touches a certificate (`docs/history/plan-websocket.md`'s explicit
scope cut). A browser connects `wss://example.com/ws`; the proxy talks
plain `ws://` to the WebSocket process behind it.

**Where this fits the two cases above:**

- **Fly.io** is the natural fit: it's already a single Docker container
  (the "2. Fly.io" Dockerfile above), so add Caddy to that same image,
  run `bin/websocket_server` and `kino` as two background processes, and
  let Caddy be the one process Fly's `EXPOSE`/health checks see — all
  three processes share `127.0.0.1` inside the one machine, satisfying
  the same-host requirement for free.
- **Render**, in its native-buildpack form, only runs one start command
  per Web Service — two separate Render services for HTTP and WebSocket
  would put them on two different hosts, breaking the cookie's automatic
  delivery to the WS handshake unless `Domain=` is set. Either switch this
  case to Render's Docker deploy path too (same multi-process-behind-Caddy
  shape as Fly above), or accept Bearer-only auth for the WS side if the
  two services must stay separate.

## 4. A single VPS (Docker Compose + Caddy)

One small server (Hetzner, DigitalOcean, Lightsail — any Linux box with
Docker) runs everything: web, WebSocket, Postgres, Redis and the proxy. It
suits a staging or closed-beta deploy of any combination in the table
above: it has no per-platform port or process limits, and `/ws` routing
(section 3) is just a Caddy rule. The cost is operational — OS patching,
backups and the firewall are yours.

Build one image from the app's Dockerfile (the one in section 2 works; drop
its `CMD`, since each service below sets its own) and run it twice with
different commands. Drop the `postgres` service for combinations without
`--postgres`/`--auth`, and the `redis` service for ones without
`--redis`/`--live`. Keep the `ws` service for combinations that use
WebSockets; it is mandatory under `--live`.

```yaml
# compose.yaml
services:
  web:
    build: .
    command: bundle exec kino -p 9292 --bind 0.0.0.0 config.ru
    env_file: .env.production
    depends_on: [postgres, redis]
  ws:
    build: .
    command: bin/websocket_server
    env_file: .env.production
    depends_on: [redis]
  postgres:
    image: postgres:16
    env_file: .env.production   # POSTGRES_PASSWORD etc.
    volumes: [pgdata:/var/lib/postgresql/data]
  redis:
    image: redis:7
  caddy:
    image: caddy:2
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
    depends_on: [web, ws]
volumes:
  pgdata:
  caddy_data:
```

```caddyfile
# Caddyfile -- same two rules as section 3, with the service names as hosts
staging.example.com {
    reverse_proxy /ws* ws:9293
    reverse_proxy web:9292
}
```

Only `caddy` publishes ports; the other services are reachable solely on
Compose's internal network, so Postgres and Redis are never exposed. Caddy
obtains and renews the Let's Encrypt certificate on its own once
`staging.example.com` points at the server.

**Env file** (`.env.production`, not committed): `MONK_ENV=staging`,
the variables from the table for your combination (`DB_HOST=postgres`,
`REDIS_URL=redis://redis:6379/0`, `AUTH_SECRET`, ...) and
`WS_ALLOWED_ORIGINS=https://staging.example.com`.

**Migrations** — run once per deploy, against the Compose Postgres:

```
docker compose run --rm web bin/setup_db
```

**Deploying** — on the server: `git pull && docker compose up -d --build`,
then the migration command above.

**Before the first build**

- `Gemfile.lock` must list the server's platform. A lockfile generated on a
  Mac only has `arm64-darwin` for native gems such as `kino`; run
  `bundle lock --add-platform x86_64-linux aarch64-linux` and commit it.
- A `Gemfile` that points `monk` at a local `path:` can't build inside the
  image; switch it to a git or gem source first.
- Open only ports 22, 80 and 443 in the firewall, and schedule a nightly
  `pg_dump` — nothing here backs up the `pgdata` volume for you.

## Open question

`config/persistence.rb` as scaffolded today only reads discrete `DB_*`
vars. Both Render and Fly can supply those directly, but Fly's default
Postgres attach flow hands you a `DATABASE_URL` instead — worth deciding
whether the scaffold should support `DATABASE_URL` out of the box (a small
`URI.parse` change) so `fly postgres attach` works with zero manual
wiring.
