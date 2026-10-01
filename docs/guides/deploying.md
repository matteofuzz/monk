# Deploying a Monk app

Example deployment cases for an app scaffolded with `monk new --postgres`
(`Gemfile`, `config.ru`, `config/load.rb`, `config/persistence.rb`,
`app/`, `bin/setup_db`, `bin/migrate`, `bin/console`, `db/migrate/`). Both cases below assume that
scaffold as the starting point.

Neither case changes anything in this repo (`monk` itself) — they describe
how a generated app deploys.

Every scaffold also ships a `Dockerfile` and `.dockerignore` — `monk new`
writes them unconditionally, and `--postgres`/`--auth` swap in a variant
that adds `libpq` for the `pg` gem's native extension. Neither the Fly.io
Dockerfile in section 2 nor the Compose setup in section 4 needs copying by
hand any more; they're shown there because those sections still have to
explain what the file does and how it's used, not because you write it
yourself.

## What each scaffold needs

An app needs what the base skeleton needs, plus the row of every flag it
was scaffolded with, including flags another flag implied (`--auth` turns
on `--postgres` and `--mail`, and `--jobs` turns on `--postgres`: see
[`scaffolding.md`](scaffolding.md), "How flags combine"; `monk new` prints
which ones it turned on).

| Flag | Processes | Services | Env vars | Extra gems |
|---|---|---|---|---|
| (base) | `bin/server`; `bin/websocket_server` only if the app uses WebSockets | none | `PUBLIC_URL` (see below) | none |
| `--postgres` | one-off `bin/setup_db` on each deploy (applies migrations) | Postgres | `DB_*` | `pg`, `dotenv` |
| `--auth` | — | — | `AUTH_SECRET`, `PUBLIC_URL` | — |
| `--mail` | — | outbound SMTP to a relay (see [`mail.md`](mail.md)) | `MAIL_URL`, `MAIL_FROM` | `net-smtp`, `dotenv` |
| `--redis` | — | Redis, only once more than one WebSocket process runs | `REDIS_URL` | `redis`, `dotenv` |
| `--live --redis` | `bin/websocket_server` **required** | Redis, **required** | `REDIS_URL`, `PUBLIC_URL` | `redis`, `dotenv` |
| `--live --postgres` | `bin/websocket_server` **required** | Postgres (`LISTEN`/`NOTIFY`), no Redis | `PUBLIC_URL` | — |
| `--jobs` | `bin/jobs` **required** (below) | Postgres | `JOBS_WORKERS`, `JOBS_QUEUES` | — |

`PUBLIC_URL` (`config/settings.rb`, every app declares it) is this app's
own origin. Its default, `http://localhost:9292`, is only harmless without
`--auth` and `--live`: `--auth`'s magic link builds itself from it, and
`--live`'s `WS_ALLOWED_ORIGINS`/`LIVE_WS_URL` default from it too, so
setting it once keeps all three in sync instead of drifting apart. See
auth.md's "Sending the magic link" and live.md's "Running it".

When the WebSocket process runs:

- It is its own deploy unit: its own port and public URL, and
  `WS_ALLOWED_ORIGINS` must match the app's origin — set `PUBLIC_URL` and
  it does, by default (below).
- With `--auth`, connections must present a valid session; without it they
  are anonymous.
- With `--redis` but not `--live`, Redis only matters once you run more than
  one WebSocket instance (the `:chat` channel then fans out through it).
  With `--live`, Redis or Postgres is the link between the app and the
  WebSocket process: with `--live --redis` the app raises at boot without
  `REDIS_URL`, and `--live --postgres` reuses the `DB_*` settings. Only
  the WebSocket process listens (`Monk::Live.listen!` at its boot, which
  fails right there if Redis or Postgres is unreachable); `bin/server`
  and `bin/jobs` only publish, and open a connection for that the first
  time they do.

**With `--jobs`**, there's one more process: `bin/jobs`, which runs the
background jobs. Like the WebSocket process it runs from the same image
with its own command (`bin/jobs`), but it serves no port and needs no
proxy route. It loads the same `config/load.rb` as `bin/server`, so give
it the same environment: `DB_*`, `MAIL_*` when the app sends mail (with
`--auth` it does: login links are sent from a job), and with `--live
--redis`, `REDIS_URL` (`config/live.rb` raises without it, and jobs can
push Live updates). It also needs the jobs migration applied (by
`bin/setup_db`, like any other).
`JOBS_WORKERS` and `JOBS_QUEUES` size it. On `TERM` it finishes the jobs
in hand, for up to 25 seconds, and puts back whatever is still running for
the next process to pick up, so a normal rolling deploy loses nothing.
Give the platform a longer stop window than that: Docker and Compose
send `KILL` 10 seconds after `TERM` by default (`stop_grace_period`, below),
and a job killed mid-run is only picked up again once another job process
notices its process went silent, after 2 minutes. Scale it by running more
instances, or with more workers per instance.

The rest of this page walks through deploying a `--postgres` app on Render
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

**Caveat**: this repo's own `Dockerfile` (the one at the root of the `monk`
gem's own source) is not what a scaffolded app uses — it bakes in *this*
repo's gemspec/git-based install path (`monkrb.gemspec` shells out to
`git ls-files`), not a generated app's plain `Gemfile`. That's not a gap
you need to work around, though: `monk new` scaffolds its own `Dockerfile`
into every app, built for exactly that plain-`Gemfile` case — see the
Fly.io case below for what it contains.

## 2. Fly.io (Docker + managed Postgres)

**Dockerfile**: already there — `monk new --postgres` (this case implies
it) writes this exact file, no `git` runtime dependency needed since a
scaffolded app's `Gemfile` pulls in `monkrb` as a normal gem (published on
rubygems.org, `require: "monk"`), not via the local gemspec:

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

EXPOSE 9292
CMD ["bin/server", "--bind", "0.0.0.0"]
```

`libpq-dev` is needed at build time for the `pg` gem's native extension;
`libpq5` — the runtime lib, no headers — is enough in the final stage. Port
9292 matches `bin/server`'s own default, not 9293 — that's `WS_PORT`'s
default for the separate WebSocket process (section 3, below); running
both on 9293 would collide them.

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

On a deploy, the WebSocket process stops on `TERM` with exit 0, like
`bin/server` and `bin/jobs`, but it drops its open sockets without a close
frame. Browsers running `monk_live.js` reconnect within a second or two
(the delay is jittered, so they don't all arrive at once) and refetch
their page to catch up, which is a burst of page requests to `bin/server`
after every WebSocket deploy. Any other client has to do the same; see
[`websocket.md`](websocket.md), "Stopping and restarting".

Setting `PUBLIC_URL=https://example.com` (matching whichever proxy config
you use below) is what makes `WS_ALLOWED_ORIGINS` and `LIVE_WS_URL` default
to values that actually fit this routing, with nothing else to configure:
`WS_ALLOWED_ORIGINS` defaults to `PUBLIC_URL` itself (`https://example.com`,
the origin browsers connect from), and `LIVE_WS_URL` defaults to
`wss://example.com/ws` outside development — exactly the `/ws` path both
snippets below route to the WebSocket process.

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
Docker) runs everything: web, WebSocket, jobs, Postgres, Redis and the proxy. It
suits a staging or closed-beta deploy of any combination in the table
above: it has no per-platform port or process limits, and `/ws` routing
(section 3) is just a Caddy rule. The cost is operational — OS patching,
backups and the firewall are yours.

Build one image from the app's own (scaffolded) Dockerfile and run it
twice with different commands — `web` needs none, since its command is
already the image's default `CMD`; `ws` overrides it. Drop the `postgres`
service for combinations without `--postgres`/`--auth`, and the `redis`
service for ones without `--redis`/`--live`. Keep the `ws` service for
combinations that use WebSockets; it is mandatory under `--live`. Keep
the `jobs` service only with `--jobs`.

```yaml
# compose.yaml
services:
  web:
    build: .
    env_file: .env.production
    depends_on: [postgres, redis]
  ws:
    build: .
    command: bin/websocket_server
    env_file: .env.production
    depends_on: [redis]
  jobs:                         # with --jobs
    build: .
    command: bin/jobs
    env_file: .env.production
    stop_grace_period: 30s      # > bin/jobs's 25s wait for jobs in flight
    depends_on: [postgres]
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
`PUBLIC_URL=https://staging.example.com` — which alone gives
`WS_ALLOWED_ORIGINS`/`LIVE_WS_URL` correct defaults (section 3, above); set
either directly instead if this app needs something that default doesn't
fit.

**Migrations** — run once per deploy, against the Compose Postgres:

```
docker compose run --rm web bin/setup_db
```

**Deploying** — on the server: `git pull && docker compose up -d --build`,
then the migration command above.

**Before the first build**

- Nothing to do for `Gemfile.lock`'s platform list: a plain `bundle install`
  already resolves and locks every compatible platform (`arm64-darwin`,
  `x86_64-linux`, `aarch64-linux`, the `-musl` variants), not just the
  machine that ran it — verified by copying a Mac-generated lockfile
  unmodified into a Linux container and building on both `aarch64-linux`
  and emulated `x86_64-linux`; both resolved the right precompiled `kino`
  gem with no extra step. (Older Bundler versions needed an explicit
  `bundle lock --add-platform`; this project's pinned toolchain doesn't.)
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
