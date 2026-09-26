# Deploying a Monk app with Postgres, Redis and SMTP — options analysis

Research only: which hosting shape costs the least effort for a `monk new
--postgres --auth --redis` app that also has to send email. Nothing here
changes `monk` itself, and nothing here supersedes `docs/guides/deploying.md` —
that doc has the two worked walkthroughs (Render native buildpack, Fly +
Docker); this one is the comparison that says *which* to reach for, plus
the platform facts checked on 2026-09-19 that the older doc predates.

## 1. What a Monk app actually requires

Everything below is read off the code, not assumed. These are the
constraints any host has to satisfy.

| # | Requirement | Where it comes from |
|---|---|---|
| R1 | **Ruby 4.0+** | `monkrb.gemspec` (`required_ruby_version >= 4.0`), `.ruby-version` 4.0.6, and `kino` itself (`>= 4.0`) |
| R2 | **A `kino` binary gem for the target platform**, or a Rust toolchain | kino 0.7.0 is a Rust (tokio/hyper) front-end; RubyGems ships precompiled `x86_64-linux`, `aarch64-linux`, both `-musl` variants, and `arm64-darwin` |
| R3 | **Two processes on one host**, `/ws*` routed to one, everything else to the other | `Monk::WebSocket::Server` is a standalone process (`lib/monk/websocket/server.rb:5`); the session cookie only rides the WS handshake automatically on the *same host* (`docs/guides/deploying.md` §3) |
| R4 | **Five discrete `DB_*` env vars**, not a `DATABASE_URL` | `lib/monk/templates/postgres/config/persistence.rb` |
| R5 | **Postgres connections ≈ (Ractor pool size × instances) + 1 per bin/* script** | one memoized `PG::Connection` per Ractor, never shared (`lib/monk/persistence/pg.rb:8-15`) |
| R6 | **A migration step that is not the start command** | `bin/setup_db` is a separate script; nothing runs it on boot |
| R7 | **`REDIS_URL`, only if WebSocket fan-out crosses processes** | `bin/websocket_server` requires `monk/websocket/redis_fanout` only when the var is set; unset = in-process fan-out, which is correct for a single-instance deploy |
| R8 | **Outbound SMTP, or HTTPS to a mail provider** | *Updated 2026-09-26:* Monk now ships `Monk::Mail` (`docs/adr/0012-minimal-built-in-mailer.md`), sending over `smtp://`/`smtps://`, so the host must allow outbound SMTP; HTTPS provider presets are planned for hosts that don't. When this doc was written, Monk had no mailer by design |
| R9 | **A writable `log/` directory** | `Monk::Log` appends to `log/<env>.log` in every environment (`lib/monk/log.rb:39-49`) — a read-only root filesystem breaks boot |
| R10 | **Env vars present in the main Ractor at boot** | `Monk::Settings` reads `ENV` at boot and seals the result shareable (`lib/monk/settings.rb`); platform-injected vars are fine, `.env` files are a dev-only convenience |

Two of these are the ones that actually decide the host: **R3** (one host,
two processes, a proxy in front) and **R2/R1** (Ruby 4.0 with a native
extension). Postgres and Redis are ordinary; SMTP is where the surprises
are (§4).

## 2. Blockers found while checking, before any host is chosen

These are repository findings, not host problems. They gate *any* deploy.

- **The `monkrb` rename has landed in code but isn't published yet —
  `bundle install` still can't resolve it from RubyGems.** `monkrb.gemspec`
  and the scaffolded `Gemfile` (`lib/monk/templates/base/Gemfile`, `gem
  "monkrb", require: "monk"`) are already renamed on this branch. But until
  `gem push` actually runs (tracked in `docs/history/release_gem.md`), a
  generated app still can't `bundle install` on a build server against the
  public name — RubyGems' `monk` remains the dormant 2009
  Janowski/Martens gem (v0.0.7, last released 2009-09-24), and `monkrb`
  itself 404s until pushed. Until then, a build needs a `git:`/`path:`
  source pointed at this repo, which drags `git` into the runtime image
  (§7.3). Once `gem push` runs, this blocker disappears and every option
  below becomes executable as written.

  Two release-side details that touch deployment rather than packaging,
  and are worth checking as part of that push rather than assumed: `gem
  "monkrb"` vs. `require "monk"` (as `rubyzip` → `require "zip"`) means the
  README needs to say so or people will require the wrong thing;
  `spec.files` shells out to `git ls-files`, so a `gem build` run anywhere
  without git — a CI container, an extracted tarball — silently produces
  an empty gem, worth a `gem contents` check before `gem push`. The
  executable stays `monk`, which the 2009 gem also ships, so the two
  conflict for anyone holding both — dormant enough not to matter, but it
  is the one collision the rename does not resolve.
- **Lockfile platforms.** The scaffold's `.gitignore` does *not* ignore
  `Gemfile.lock`, so the app commits it. A lockfile resolved on an Apple
  Silicon laptop carries only `arm64-darwin`; a Linux build box then has
  no `kino` binary to use and falls back to compiling Rust (or fails
  outright under `BUNDLE_FROZEN`). `bundle lock --add-platform
  x86_64-linux aarch64-linux` is a prerequisite step for every Docker or
  buildpack deploy — it is in no scaffold and in no doc.
- **`rackup`/`webrick` are dead weight** in the scaffolded `Gemfile` once
  `kino` serves the app; harmless, but they make a build slower and a
  reader think WEBrick is the production server.
- **Logs never reach stdout outside development.** `Monk::Log` writes the
  file always, and `Base#log_request` echoes to `$stdout` only in
  development — so on any platform whose log aggregation reads stdout
  (all of them), a production deploy shows nothing but the boot banner,
  while the real access log accumulates on an ephemeral disk that is
  discarded on the next deploy. Worth a conscious decision before picking
  a host, since it is the host's log pane that goes quiet.

## 3. The options, ranked by effort

Ranking assumes the full stack: Postgres **and** Redis **and** outbound
email, with the WebSocket process in play (R3). Drop the WebSocket process
and every option gets easier by roughly the same amount, which is why R3
is what separates them.

### 3.1 One VPS + Docker Compose (Hetzner/DigitalOcean/Scaleway) — easiest

One `compose.yml` with four services — Caddy, `kino`, `bin/websocket_server`,
`postgres:16`, `redis:7` — is the only shape that satisfies R3 by
construction: all processes share `127.0.0.1`, path routing is the four
lines of Caddyfile already in `docs/guides/deploying.md`, and Caddy gets the TLS
certificate itself.

- **R1/R2**: `ruby:4.0-slim` base image, precompiled `kino` for the
  matching arch. No platform runtime to wait on.
- **R4**: set the five `DB_*` vars directly — no URL to parse, unlike
  every managed Postgres below.
- **R5**: Postgres' own `max_connections` is yours to raise.
- **R6**: `docker compose run --rm app bin/setup_db`.
- **R8**: the decisive one — **port 587 is open from day one**, no plan
  upgrade and no support ticket, which is true of no managed platform in
  this list (§4).
- **Cost**: ~€4–6/month all-in (CX22-class box), everything included.
- **Price paid**: backups, Postgres upgrades and OS patching are yours.
  [Coolify or Dokku](https://dev.to/abhijais1/self-hosted-paas-in-2026-coolify-vs-dokku-vs-caprover-vs-ownkube-126m)
  on the same box buys back a dashboard and push-to-deploy; Coolify also
  manages Postgres/Redis as first-class services and deploys Compose
  stacks directly, at ~700 MB of RAM overhead versus Dokku's ~150 MB.

### 3.2 Railway — easiest *managed* option

Postgres and Redis are one-click services in the same project, reachable
over private networking, and the app deploys straight from the Dockerfile.

- **R3**: Railway services are separate containers, so the two Monk
  processes must be **one** service running Caddy + `kino` +
  `bin/websocket_server` (same image as §3.1), or the session cookie stops
  reaching the WS handshake.
- **R4**: Railway's Postgres exposes `PG*`/`DATABASE_URL` variables, but
  its variable references let you map them onto `DB_HOST`/`DB_PORT`/… with
  no code change — the cleanest answer to R4 of any managed host.
- **R8**: **outbound SMTP (25/465/587) is Pro-plan-only**; Free, Trial and
  Hobby have it disabled, and Railway's own advice is to use a provider's
  HTTPS API instead.
- **Cost**: ~$20–45/month for web + Postgres + Redis, usage-billed.

### 3.3 Render — the existing walkthrough, with three corrections

`docs/guides/deploying.md`'s Render case still works, but three of its premises
have changed or need qualifying:

- **Migrations (R6)**: the doc says Render has no one-off pre-deploy step,
  so run `bin/setup_db` as a Job. Render now has a **pre-deploy command**
  that runs before each deploy — the right home for `bin/setup_db`. It is
  unavailable on free instance types and burns pipeline minutes.
- **Redis (R7)**: Render's managed offering is **Render Key Value**, which
  runs **Valkey 8**, not Redis. The `redis` gem speaks to it, and
  `redis`/`keyvalue` are interchangeable in a Blueprint, but it is worth
  saying out loud that a Monk app's fan-out would be running on Valkey.
- **Ruby (R1)**: the doc's Render case uses the **native Ruby runtime**,
  whose default has been 3.3.x and whose 4.0 availability could not be
  confirmed from here (`render.com` and `docs.render.com` are both
  unreachable behind this environment's egress proxy). Until someone
  confirms it, **deploy Render via Docker**, not the buildpack — which
  also fixes R3, since the native runtime allows only one start command
  per service.
- **R8**: port 25 is blocked for **all** Render services; 465/587 work on
  paid instances only — free web services lost outbound SMTP entirely in
  September 2025.

### 3.4 Fly.io — most capable, most moving parts

The Fly case in `docs/guides/deploying.md` is the one that has aged worst:

- **`fly postgres create` is deprecated.** Unmanaged Fly Postgres is no
  longer supported; `fly mpg` (Managed Postgres) replaces create/attach.
  It hands you a `DATABASE_URL`, so R4's open question in
  `docs/guides/deploying.md` is now unavoidable rather than optional: either
  parse the URL in `config/persistence.rb` or set the five vars by hand
  from the MPG connection details.
- **Redis** is Upstash-backed (`fly redis`). `RedisFanout` subscribes with
  **`psubscribe` over a TCP connection** held open inside a dedicated
  Ractor (`lib/monk/websocket/redis_fanout.rb`) — pattern subscriptions on
  a serverless Redis are exactly the kind of thing to verify before
  committing, since Upstash's pub/sub story is built around its REST/SSE
  path. Unverified here.
- **R3** is satisfied the way §3.1 is: one machine, Caddy plus both
  processes, since Fly `[processes]` groups land on *separate* machines.
- **R8**: port 25 is blocked, and 465/587 historically require a support
  request — community threads asking for exactly that are still being
  opened in 2026.

### 3.5 Heroku — not evaluated further

Attractive on paper (Postgres, Key-Value and an email add-on all in one
dashboard, which no other option offers), but `devcenter.heroku.com` is
unreachable from this environment, so Ruby 4.0 buildpack support could not
be confirmed — and R3 needs a Docker deploy there too. Worth a look only
if the add-on marketplace is the deciding factor.

## 4. SMTP: the part with no framework support

> **Update 2026-09-26:** this section predates `Monk::Mail`
> (`docs/adr/0012-minimal-built-in-mailer.md`, `docs/guides/mail.md`),
> which now does what it describes: MIME built by Monk, a `Net::SMTP`
> client built per send inside the worker Ractor, credentials sealed at
> boot from one `MAIL_URL`. Point 1 also turned out to understate the
> problem: measured on Ruby 4.0.6, the `mail` gem (2.9.1) raises
> `Ractor::IsolationError` on `Mail.new` in any worker Ractor, so it is
> unusable there, not just a poor fit. The port policy below still
> decides the host.

Monk will not grow a mailer — `Monk::Auth.request_login` returns the raw
token and the app delivers it (`docs/design/auth-sessions.md`), and
`Monk::Auth.log_dev_link` covers development only (it is a no-op outside
`Monk.env.development?`). So "add SMTP" means the app does it, inside a
route handler, inside a worker Ractor. Three consequences:

1. **A mailer object cannot live in a route closure.** It fails `freeze!`
   with `UnshareableRouteError`, by design. Whatever sends the mail has to
   be constructed per request inside the Ractor that serves it — the same
   pattern `PG::Connection` already follows (R5). The `mail` gem's global
   configuration makes it a poor fit for that; stdlib `Net::SMTP` or
   `Net::HTTP` (for a provider's API), both built fresh per call, fit
   cleanly.
2. **Credentials should come from `Settings`, not `ENV`, at request
   time.** `Settings` reads `ENV` in the main Ractor at boot and seals the
   values shareable; whether `ENV` is readable from a non-main Ractor on
   Ruby 4.0 is still an open question in this repo
   (`docs/design/auth-sessions.md`, `docs/history/plan-auth.md` Phase 5). `Net::SMTP` is a
   bundled, not default, gem since Ruby 3.1 — it needs its own Gemfile
   line.
3. **Every send blocks a worker Ractor.** Monk has no job queue
   (`docs/history/notes-post-core.md` lists async jobs as a candidate), so an SMTP handshake
   inside `POST /auth/request` occupies one pool slot for its full
   round-trip. With a small pool that is a real capacity limit, and it
   argues for a fast HTTPS API call with a tight timeout over a
   multi-round-trip SMTP conversation.

**Port policy is the deciding factor between hosts**, and it is uniformly
hostile on managed platforms:

| Host | 25 | 465 | 587 |
|---|---|---|---|
| Own VPS (Hetzner) | blocked for new accounts, unblockable on request after ~1 month | same as 25 | **open immediately** |
| Railway | blocked | Pro plan and above only | Pro plan and above only |
| Render | blocked (all plans) | paid instances only | paid instances only |
| Fly.io | blocked | support request in practice | support request in practice |

A VPS is not "no blocking" — it is *the one place 587 works on day one*,
which is all a relay needs. Nobody should be sending on 25 from an app
server anyway: that is direct-to-MX delivery, i.e. running your own MTA.

So: **on a VPS, real SMTP is fine. On a PaaS, prefer a provider's HTTPS
API** — same provider, same deliverability, no port policy. Free tiers as
of 2026: Brevo 9,000/month (300/day), Mailtrap ~4,000/month, Resend
3,000/month, Amazon SES $200 of AWS credits for 6 months (new accounts; the old
3,000/month offer is gone, per `docs/mail-providers.md`), Postmark 100/month
(integration testing only). For magic-link auth, volume is tiny and
deliverability is everything — Postmark or Resend on a paid tier, with a
verified sending domain (SPF/DKIM), is the sane default; a login link in
spam is an outage.

## 5. Recommendation

- **Fewest moving parts, and the only option where "an SMTP" literally
  works: one VPS running Docker Compose** (Caddy + `kino` +
  `bin/websocket_server` + Postgres + Redis), optionally under Coolify for
  a UI. It satisfies R3 for free, R4 without a shim, and R8 without a
  plan upgrade, at ~€5/month.
- **If the operational burden is unwelcome: Railway**, one service running
  all three processes behind Caddy, its managed Postgres and Redis
  alongside, and mail over a provider's HTTPS API rather than SMTP.
- **One repo-side blocker is left** (§2): the `gem push` to RubyGems
  itself, tracked in `docs/history/release_gem.md`. Everything else the
  rename touches — the gemspec, the scaffold `Gemfile`, and
  `bundle lock --add-platform x86_64-linux aarch64-linux` — is already
  done and verified in `docs/guides/deploying.md` §4; it was never
  actually about the framework's name, since it's `kino`'s precompiled
  binaries at stake either way.

## 6. Open questions

1. Should `config/persistence.rb` accept `DATABASE_URL` (R4)? The answer
   is now clearly *yes* — Fly MPG only offers a URL, and Render/Railway
   both lead with one. `docs/guides/deploying.md` raised this as an open
   question; this analysis closes it in favour of supporting both.
2. Does `RedisFanout`'s `psubscribe` work against Upstash (Fly) and
   Valkey 8 (Render Key Value)? Unverified; a 10-minute check that gates
   §3.3 and §3.4.
3. Should `Monk::Log` mirror to stdout outside development, or is a
   platform-visible access log the operator's problem (§2)?
4. Is Ruby 4.0 available on Render's and Heroku's native runtimes? Both
   documentation sites are blocked from this environment; until answered,
   both cases are Docker-only.

## Sources

Checked 2026-09-19.

- [Fly Postgres (Unmanaged) — deprecated in favour of `fly mpg`](https://fly.io/docs/postgres/)
- [Upstash for Redis on Fly](https://fly.io/docs/upstash/redis/)
- [Outbound port 25 blocked by default on Fly](https://community.fly.io/t/outbound-port-25-direct-to-mx-smtp-blocked-by-default-on-new-accounts/28537)
- [Request to unblock outbound SMTP (port 587) on Fly](https://community.fly.io/t/request-to-unblock-outbound-smtp-port-587-for-app-rialma-api/27164)
- [Render Key Value runs Valkey 8](https://render.com/docs/valkey-faq)
- [Render: run migrations with the pre-deploy command](https://render.com/changelog/predeploy-command)
- [Render: free web services lose outbound SMTP ports](https://render.com/changelog/free-web-services-will-no-longer-allow-outbound-traffic-to-smtp-ports)
- [Railway outbound networking — SMTP is Pro-plan-only](https://docs.railway.com/networking/outbound-networking)
- [Railway pricing, 2026](https://dev.to/nayankyada/railway-pricing-2026-free-tier-limits-usage-costs-when-to-upgrade-1acm)
- [Self-hosted PaaS in 2026: Coolify vs Dokku vs CapRover](https://dev.to/abhijais1/self-hosted-paas-in-2026-coolify-vs-dokku-vs-caprover-vs-ownkube-126m)
- [Free transactional email tiers compared, 2026](https://www.brevo.com/blog/free-smtp-servers/)
- [`kino` on RubyGems](https://rubygems.org/gems/kino) — 0.7.0, Ruby >= 4.0, precompiled linux/darwin platforms
- [`monk` on RubyGems](https://rubygems.org/gems/monk) — the unrelated 2009 gem holding the name

---

## 7. Option 1 in detail — one VPS, one Compose file

Expanded from §3.1. Still analysis: what the shape is, what it costs, what
it gets wrong if you are not careful. No files are generated for it.

### 7.1 Topology and the port map

Five containers on one box, one network, exactly one of them published:

| Container | Binds | Published | Role |
|---|---|---|---|
| `caddy` | `:80`, `:443` | yes | TLS, the only internet-facing process; routes `/ws*` to the WS container, everything else to the app |
| `app` | `:9292` | no | `kino` serving `config.ru` |
| `ws` | `:9293` | no | `bin/websocket_server` |
| `postgres` | `:5432` | no | `postgres:16`, named volume |
| `redis` | `:6379` | no | `redis:7`, no persistence needed (§7.6) |

This is the shape R3 wants: Caddy, `kino` and the WS process share one
host, so the `HttpOnly` session cookie reaches the WS handshake with no
`Domain=` attribute and no Bearer fallback. The Caddyfile is the
four-line one already in `docs/guides/deploying.md` §3 — nothing new to design.

**Port collision to avoid.** `kino`'s optional read-only control plane is
documented with `control_bind "127.0.0.1:9293"`, and 9293 is exactly the
port `bin/websocket_server` defaults to (`WS_PORT`, and this repo's own
`Dockerfile` `EXPOSE`s it too). On a single host that is a real clash:
give the control plane its own port, or move the WS process with
`WS_PORT`.

### 7.2 Sizing, which is smaller than Rails instinct suggests

`kino -w` defaults to `Kino.available_parallelism` — one Ractor worker per
core — and in `:ractor` mode the default is **1 thread per worker**. Monk
opens one memoized `PG::Connection` per Ractor (R5). So on a 2 vCPU box:

```
Postgres connections = 2 workers × 1 thread = 2, plus 1 while bin/setup_db runs
```

Against `postgres:16`'s default `max_connections = 100` that is noise.
Connection exhaustion — the thing that forces PgBouncer into most small
Rails deploys — is not a concern at this shape, and there is no pooler to
introduce. It only becomes one if the app is scaled to several `kino`
containers *and* the box grows cores: the number to watch is
`instances × workers × threads`.

The WebSocket side scales differently: `Server#run` spawns **one Ractor
per accepted connection**, with no cap in the accept loop
(`lib/monk/websocket/server.rb`). Concurrent socket count, not request
rate, is what sizes RAM on this box, and nothing in Monk refuses the
N+1st connection — on a public endpoint that is the limit worth measuring
before launch.

A CX22-class box (2 vCPU / 4 GB / 80 GB, €4.49/month as of April 2026,
before Hetzner's June 2026 adjustment) comfortably holds all five
containers. Coolify on the same box adds roughly 700 MB of resident
memory, Dokku roughly 150 MB — relevant on 4 GB, irrelevant on 8.

### 7.3 One image, two commands

The `app` and `ws` containers are the *same* image with different
commands (`bin/server` vs `bin/websocket_server`), which keeps the build
single and guarantees both run identical code. Build notes:

- `ruby:4.0-slim` base (R1); `libpq-dev` at build time, `libpq5` at
  runtime, as `docs/guides/deploying.md` §2 already works out.
- **No Rust toolchain needed** — provided the committed `Gemfile.lock`
  carries `x86_64-linux` (or `aarch64-linux`), per §2. If it does not,
  this build is where it surfaces, as a surprise `cargo` compile or a
  frozen-lockfile failure.
- **`git` is needed at build *and* run time only until `monkrb` is
  published** (§2). While the app's `Gemfile` pulls the framework from a
  git source, the runtime stage needs `git` for the reason this repo's own
  `Dockerfile` documents: Bundler re-evaluates the gemspec on every
  `bundle exec`, and `monkrb.gemspec` shells out to `git ls-files`. Once
  `gem "monkrb"` resolves from RubyGems, `git` drops out of the runtime
  stage entirely and the final image is `ruby:4.0-slim` + `libpq5` and
  nothing else.
- Drop `rackup`/`webrick` from the app's Gemfile; `kino` is the server.

### 7.4 Lifecycle: health checks work, WS shutdown does not

- **Readiness.** `kino`'s control plane (`control_bind`, optionally behind
  `control_token`) serves `GET /ready` — 200 when serving, 503 during boot
  and drain — plus `/live`, `/stats` and `/metrics` (Prometheus). That is
  the Compose healthcheck for the `app` container, and what Caddy should
  wait on before sending traffic.
- **Graceful HTTP shutdown.** `kino` traps INT/TERM and drains, with a
  configurable `shutdown_timeout` (default 30s) — so set the app
  container's `stop_grace_period` above it, or Docker kills the drain.
- **The WS process has no graceful shutdown under Docker.**
  `Server#run` rescues `Interrupt` only — i.e. SIGINT. `docker compose
  stop` sends **SIGTERM**, which Ruby handles by terminating immediately:
  the listen socket is not closed cleanly, no RFC 6455 close frames are
  sent, and every connection Ractor dies mid-frame. Clients see an
  abnormal 1006 close and must reconnect, and the scaffold's chat has no
  resume. `STOPSIGNAL SIGINT` on that image (or `docker stop --signal`)
  routes Docker's stop into the path the server actually implements —
  worth knowing before the first deploy rather than after.
- **Deploys are brief downtime.** One box, no blue/green: `docker compose
  up -d` recreates the containers. Caddy holding the socket softens it;
  true zero-downtime needs two app containers and a Caddy upstream list,
  which is the point at which §3.2's managed option starts looking
  cheaper in effort.

### 7.5 Migrations and secrets

`bin/setup_db` is idempotent (applied versions live in
`schema_migrations`), so R6 is a one-liner run against the same network:
`docker compose run --rm app bin/setup_db`, before `up -d` on a deploy
that adds a migration. No release-phase concept exists here, which is a
feature: the step is explicit and its output is in front of you.

Secrets come from a root-owned `env_file` on the host, never from a `.env`
baked into the image — `Monk::Settings` reads `ENV` once in the main
Ractor at boot and seals the values shareable (R10), so platform-injected
vars are all it ever needs. `dotenv` stays what the scaffold intends it to
be: a development convenience.

### 7.6 State: what needs a volume and what does not

- **Postgres** needs a named volume, and a real backup: a nightly
  `pg_dump` from a one-off container to object storage is the minimum.
  Hetzner's own snapshot/backup add-ons cover the disk, not a consistent
  dump — they are a different guarantee, not a substitute.
- **Redis needs neither.** `RedisFanout` is pure pub/sub relay — it
  publishes and `psubscribe`s on `monk:ws:*` and keeps no state; the
  design notes say explicitly that a broadcast still reaches local
  connections directly if Redis is briefly away. Run it with persistence
  off and treat it as restartable. Also note that on **one** box with one
  WS container, `REDIS_URL` can simply be left unset (R7) — the fan-out
  is already in-process, and the container drops out of the stack
  entirely. Redis earns its place here only as headroom for a second WS
  process later.
- **`log/`** (R9) needs a writable path, and either a named volume or the
  acceptance that each deploy discards the access log. Since `Monk::Log`
  never echoes to stdout outside development, `docker compose logs` will
  be near-silent either way — on this option you at least *can* mount the
  directory and tail it.

### 7.7 Mail on this box

Port 587 is open on a Hetzner cloud server from day one (§4), so a
provider relay works with no plan upgrade and no support ticket: this is
the only option in this document where "add an SMTP" is literally true.
Ports 25 and 465 are blocked for roughly the first month and unblockable
on request afterwards — irrelevant, since sending on 25 means running an
MTA, which nobody should do for magic links.

What still applies, because it is Monk's shape and not the host's (§4):
the client is built per request inside the worker Ractor, credentials come
from `Settings` rather than a request-time `ENV` read, and the send blocks
a pool slot — which on a 2-core box means **one of two**. That is the
strongest argument on this option for a fast HTTPS API call with a tight
timeout over a multi-round-trip SMTP conversation, even though SMTP is
available. DNS work (SPF, DKIM, DMARC on the sending domain) is unchanged
by the hosting choice.

### 7.8 What you are accepting

- One box: no HA, and a reboot is an outage. Postgres shares CPU with the
  app, so a heavy query is a slow request.
- Postgres upgrades, OS patching and backup *verification* are yours.
- The scaling path is graceful, though: move Postgres to a managed
  instance first (the five `DB_*` vars already point anywhere), keep the
  box for the app, and only then reconsider the platform.

Pick §3.2 instead the moment "nobody wants to own the database" is true —
that, not cost and not the Monk-side constraints, is the line between
these two options.

### 7.9 Sources added for this section

- [Hetzner: port 25/465 restricted on new cloud accounts, 587 open](https://queensmtp.com/smtp-settings/hetzner)
- [Hetzner CX22 pricing, 2026](https://bestusavps.com/reviews/hetzner/) and the [June 2026 price adjustment](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)
- [`kino` README](https://github.com/yaroslav/kino) — `-w` defaults to `Kino.available_parallelism`, ractor mode defaults to 1 thread per worker, `control_bind`/`control_token` with `/ready`, `/live`, `/stats`, `/metrics`, INT/TERM drain with a 30s `shutdown_timeout`
