# Deploying a Monk app

What an app needs in production, module by module, then four ways to
run it: Render (section 1), Fly.io (section 2), adding the WebSocket
process to either (section 3), and a single VPS with Docker Compose
(section 4). The examples start from an app made with
`monk new my_app --with postgres`.

`monk new` writes a `Dockerfile` and `.dockerignore` into every app.
The only system package is a compiler in the build stage, for the few
gems that build a native extension (`irb`'s dependencies); kino and
`pg` (1.6+, which brings its own `libpq`) are precompiled gems.
Section 2 shows the file.

## What each module needs

An app needs what the base app needs, plus the row of every module it has
(`monk add --list` marks them; [`scaffolding.md`](scaffolding.md) says what
each is). `monk add` lists the values to set before production for the
modules it adds.

| Module | Processes | Services | Env vars | Gems |
|---|---|---|---|---|
| (base) | `bin/server` | none | `MONK_ENV`, `PUBLIC_URL` (see below) | none |
| `postgres` | one-off `bin/setup_db` on each deploy (applies migrations) | Postgres | `DB_*` | `pg` |
| `redis` | — | Redis | `REDIS_URL` | `redis` |
| `mail` | — | outbound SMTP to a relay (see [`mail.md`](mail.md)) | `MAIL_URL`, `MAIL_FROM` | `net-smtp` |
| `auth` | — | — | `AUTH_SECRET`, `PUBLIC_URL` | — |
| `jobs` | `bin/jobs` **required** (below) | Postgres | `JOBS_WORKERS`, `JOBS_QUEUES` | — |
| `websocket` | `bin/websocket_server` **required** | its transport: Postgres (`LISTEN`/`NOTIFY`) or Redis | `WS_ALLOWED_ORIGINS` (origins besides `PUBLIC_URL`), `WS_PROCESSES` (1) | — |
| `live` | (websocket's) | — | `PUBLIC_URL`, `LIVE_WS_URL` (default from it) | — |
| `presence` | (websocket's and `bin/server`) | Postgres, **a direct connection** from `bin/server` (below) | — | — |
| `storage` | — | an S3-compatible bucket, with a CORS rule for `PUBLIC_URL` and a `tmp/` lifecycle rule (see [`storage.md`](storage.md)) | `STORAGE_URL`; `STORAGE_SECRET` only with `file://` | — |

`MONK_ENV` is `production` (or `staging`) wherever the app is deployed.
Unset, it means `development`, and the app runs that way without an
error: mail is printed instead of sent, magic links are logged, auth
cookies aren't `Secure`, demo routes are on, and storage signs its links
with a public value. The scaffolded `Dockerfile` sets
`MONK_ENV=production`, and the platform's own env can override it (as
the VPS case below does with `staging`). Without the Dockerfile (Render's
native buildpack), set it in the platform's env vars. `bin/server` warns
when it listens beyond the machine (`--bind 0.0.0.0`) with `MONK_ENV`
unset.

`PUBLIC_URL` (`config/settings.rb`, every app declares it) is this app's
own origin. Its default, `http://localhost:9292`, is only harmless without
auth and live: auth's magic link builds itself from it, the WebSocket
server always allows it as an origin, and live's `LIVE_WS_URL` defaults
from it, so setting it once keeps all three in sync instead of drifting
apart. See auth.md's "Sending the magic link" and live.md's "Running it".
Outside development and test, boot refuses a `PUBLIC_URL` on `http://` or
on a placeholder host like `example.com`, and the other values in
[`settings.md`](settings.md#values-refused-at-boot).

When the WebSocket process runs:

- It is its own deploy unit: its own port and public URL. It allows
  sockets from `PUBLIC_URL`, plus any origins in `WS_ALLOWED_ORIGINS`
  (below).
- With auth, a socket carries its user's session: required for the app's
  own socket handler, optional with live (whose rules decide what visitors
  get).
- The transport in `config/websocket.rb`, Redis or Postgres, is the link
  between the app and the WebSocket process: with Redis the app needs
  `REDIS_URL` outside development, and with Postgres it reuses the `DB_*`
  settings. Only the WebSocket process listens (at its boot, which fails
  right there if Redis or Postgres is unreachable); `bin/server` and
  `bin/jobs` only publish, and open a connection for that the first time
  they do.
- It sets its own GC settings, the three
  `RUBY_GC_HEAP_FREE_SLOTS_*_RATIO`s, by starting itself again with them
  once at boot; any you set win. On Ruby 4.0 they cut GC pauses while
  thousands of sockets are open, for ~30% more memory
  ([`websocket.md`](websocket.md#in-a-monk-app-monk-add-websocket)). A
  process manager sees the same PID throughout.
- Past ~5K open sockets, `WS_PROCESSES` runs several server processes on
  its port, each with its own GC pauses
  ([`websocket.md`](websocket.md#several-processes)): on one host or in
  one container. Replicas of the service behind the proxy do the same
  across containers.

**With jobs**, there's one more process: `bin/jobs`, which runs the
background jobs. Like the WebSocket process it runs from the same image
with its own command (`bin/jobs`), but it serves no port and needs no
proxy route. It loads the same `config/load.rb` as `bin/server`, so give
it the same environment: `DB_*`, `MAIL_*` when the app sends mail (with
auth it does, if login links are sent from a job), and `REDIS_URL` when
Redis is websocket's transport (jobs can push Live updates through it).
It also needs the jobs migration applied (by `bin/setup_db`, like any
other). `JOBS_WORKERS` and `JOBS_QUEUES` size it. On `TERM` it finishes
the jobs in hand, for up to 25 seconds, and puts back whatever is still
running for the next process to pick up, so a normal rolling deploy
loses nothing. Give the platform a longer stop window than that: Docker
sends `KILL` 10 seconds after `TERM` by default, and the Compose file
`monk add deploy` writes gives `web` and `jobs` 35 s
(`stop_grace_period`). A job killed mid-run is only picked up again
once another job process notices its process went silent, after 2
minutes. Scale it by running more instances, or with more workers per
instance.

**With presence**, nothing new to run: `bin/websocket_server` counts the
signed-in sockets, and `bin/server` reacts to changes
([`presence.md`](presence.md)). Two things to plan for:

- `bin/server` holds a Postgres session for presence's `LISTEN` and the
  lock that elects which process reacts, so it needs a direct connection:
  not through PgBouncer in transaction mode (session mode is fine).
- Each `bin/server` process opens one more connection to Postgres, and the
  one reacting one more again: N web processes, N + 1. Each
  `bin/websocket_server` process opens one for its counts. Count them
  against the database's connection limit.

If a host or pod vanishes without closing its connections, the reacting
process's lock is freed in about 25 s (short TCP keepalives on that
connection), and another process takes over within 5 s more.

## Health check

Every Monk app answers `GET /_monk/up` with `204`: before routing, with
no session or database, and not logged. Point a platform's health check
at it (Render's Health Check Path, Fly's `[[http_service.checks]]`). It
means "the process answers requests"; a check of the database is a
route of your own. The offline client checks it too, to know when the app
is back ([`offline.md`](offline.md#get-_monkup)).

## 1. Render (native Ruby buildpack + managed Postgres)

**Local setup**

```
monk new my_app --with postgres
cd my_app && bundle install
```

**Render resources**

1. **New PostgreSQL** — create it first; note the Hostname, Port, Database,
   Username, Password shown on the instance's Info page (internal
   connection, same region as the web service).
2. **New Web Service**, pointed at the repo:
   - Environment: `Ruby`
   - Build command: `bundle install`
   - Start command: `bin/server --bind 0.0.0.0` (Render injects `PORT`,
     which `bin/server` passes to Kino; `--bind 0.0.0.0` makes it
     reachable, since Kino defaults to localhost)
   - Env vars: `MONK_ENV=production` (the buildpack doesn't use the
     Dockerfile, which sets it), `PUBLIC_URL`, and `DB_HOST`, `DB_PORT`,
     `DB_USER`, `DB_PASSWORD`, `DB_NAME` — filled in from the Postgres
     instance's Info page. `config/persistence.rb` reads exactly these five
     vars, not a `DATABASE_URL`.

**Migrations**

Render web services don't run one-off pre-deploy commands by default, so
run `bin/setup_db` (which calls `Migrator#migrate!`) as a Render **Job**
against the same Postgres instance — manually per deploy, or wired to a
Deploy Hook. `bin/setup_db` is idempotent (applied versions are tracked in
`schema_migrations`), so re-running it is safe.

## 2. Fly.io (Docker + managed Postgres)

**Dockerfile**: `monk new` writes this one:

```dockerfile
FROM ruby:4.0-slim AS builder
WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential \
  && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock* ./
RUN bundle install

FROM ruby:4.0-slim
WORKDIR /app

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY . .

ENV MONK_ENV=production

EXPOSE 9292
CMD ["bin/server", "--bind", "0.0.0.0"]
```

`MONK_ENV=production` is the default for every process this image runs
(`bin/server`, `bin/jobs`, `bin/setup_db`); `fly secrets set
MONK_ENV=staging` overrides it for a staging app.

`build-essential` is only in the build stage: `monk add postgres` adds
`irb` (for `bin/console`), and its dependencies (`erb`, `io-console`,
`prism`) compile native extensions. The image that runs has no compiler.
The `pg` gem (1.6+) installs precompiled for Linux with its own `libpq`, so
neither stage needs `libpq-dev` or `libpq5`. Port 9292 is `bin/server`'s
default; the WebSocket process's is 9293 (`WS_PORT`, section 3).

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

`Monk::WebSocket::Server` is its own process on its own port, never
Kino's. A reverse proxy in front routes by path: `/ws` to the WebSocket
process, everything else to Kino. This has to be **path-based routing
on the same host**, not a separate subdomain, unless the session cookie
is given `Domain=<shared parent domain>`: cookies aren't port-scoped,
so the browser sends the session cookie with the WebSocket handshake
only within the same host ([Identity crosses the process
boundary](../design/websocket.md#identity-crosses-the-process-boundary-the-same-way-it-crosses-ractors)).
`monk add deploy` writes this rule for Docker Compose (section 4); the
Caddy and nginx examples below are for other setups.

On a deploy, the WebSocket process stops on `TERM` with exit 0, like
`bin/server` and `bin/jobs`, but it drops its open sockets without a close
frame. Browsers running `monk_live.js` reconnect within a second or two
(the delay is jittered, so they don't all arrive at once) and refetch
their page to catch up, which is a burst of page requests to `bin/server`
after every WebSocket deploy. Any other client has to do the same; see
[`websocket.md`](websocket.md), "Stopping and restarting".

Setting `PUBLIC_URL=https://app.your-domain.com` (matching whichever proxy
config you use below) is all this routing needs: the WebSocket server
allows that origin, the one browsers connect from, and `LIVE_WS_URL`
defaults to `wss://app.your-domain.com/ws` outside development — exactly
the `/ws` path both snippets below route to the WebSocket process.

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
Monk process ever touches a certificate. A browser connects
`wss://example.com/ws`; the proxy talks plain `ws://` to the WebSocket
process behind it.

**Idle timeouts.** A proxy closes a WebSocket that carries nothing for a
while: nginx after 60 s (`proxy_read_timeout`), Cloudflare after 100 s;
Caddy has no idle timeout by default. The scaffolded
`bin/websocket_server` pings every 25 s (`ping_interval:`), which keeps a
quiet page's socket open under all of them, and closes a socket whose
browser stopped answering ([`websocket.md`](websocket.md)). If you
raise `ping_interval:`, keep it under your proxy's timeout.

**Where this fits the two cases above:**

- **Fly.io** is the natural fit: it's already a single Docker container
  (the "2. Fly.io" Dockerfile above), so add Caddy to that same image,
  run `bin/websocket_server` and `bin/server` as two background processes, and
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

`monk add deploy` writes the stack, from the modules the app has:

- `compose.yaml`: the app's image as `web`, and as `ws` and `jobs` with
  websocket and jobs; `postgres` and `redis` with theirs; Caddy in front.
  A `log` volume holds `log/<MONK_ENV>.log`, since Monk doesn't log to
  stdout. `web` has a health check on `/_monk/up` (with Ruby: the slim
  image has no `curl`), so `docker compose up -d --wait` waits for it.
- `Caddyfile`: `/ws*` to `ws:9293`, the rest to `web:9292`, on one host,
  so the session cookie reaches the WebSocket handshake (section 3). Caddy
  checks `web` at `/_monk/up` every 10 s; while it doesn't answer (a
  deploy, a crash) pages get a 502 or 503, which an installed app shows as
  its offline page ([`offline.md`](offline.md)).
- `.env.production.example`: every setting the modules need, with
  Compose's service names (`DB_HOST=postgres`,
  `REDIS_URL=redis://redis:6379/0`).
- `bin/deploy_env`: run on the server, it writes `.env.production` and
  fills in the secrets there: `AUTH_SECRET`, the database password, and
  the push key pair through `monk push keys` in the built image.

A module added later adds its own services and settings. On the server:

```
bin/deploy_env
docker compose build
docker compose up -d --wait postgres          # with postgres
docker compose run --rm web bin/setup_db      # with postgres, every deploy
docker compose up -d
```

Only `caddy` publishes ports; the other services are reachable solely on
Compose's internal network, so Postgres and Redis are never exposed. Caddy
obtains and renews the Let's Encrypt certificate on its own once
`SITE_ADDRESS` points at the server.

Every step on Hetzner Cloud, with Brevo for mail, from the accounts to
backups: [`deploy-hetzner.md`](deploy-hetzner.md).

**Before the first build**

- `Gemfile.lock` must list the server's platform (`x86_64-linux` or
  `aarch64-linux`). A lockfile made with Ruby 4's Bundler lists every
  platform (`arm64-darwin`, `x86_64-linux`, `aarch64-linux`, the `-gnu`
  and `-musl` variants), checked on 2026-11-20. One made before keeps the
  platforms it started with, often only the developer's machine:
  `bundle lock --add-platform x86_64-linux aarch64-linux` adds them.
- A `Gemfile` that points `monk` at a local `path:` can't build inside the
  image; switch it to a git or gem source first.
- Open only ports 22, 80 and 443 (and UDP 443 for HTTP/3) in the
  firewall.
- `.env.production` is part of every backup: restoring a database under
  a new `AUTH_SECRET` leaves every session stuck, and under a new VAPID
  pair every push subscription dead. Save it beside each `pg_dump`.
