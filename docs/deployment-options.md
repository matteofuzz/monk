# Deploying a Monk app with Postgres, Redis and SMTP — options analysis

Research only: which hosting shape costs the least effort for a `monk new
--postgres --auth --redis` app that also has to send email. Nothing here
changes `monk` itself, and nothing here supersedes `docs/deploying.md` —
that doc has the two worked walkthroughs (Render native buildpack, Fly +
Docker); this one is the comparison that says *which* to reach for, plus
the platform facts checked on 2026-09-19 that the older doc predates.

## 1. What a Monk app actually requires

Everything below is read off the code, not assumed. These are the
constraints any host has to satisfy.

| # | Requirement | Where it comes from |
|---|---|---|
| R1 | **Ruby 4.0+** | `monk.gemspec` (`required_ruby_version >= 4.0`), `.ruby-version` 4.0.6, and `kino` itself (`>= 4.0`) |
| R2 | **A `kino` binary gem for the target platform**, or a Rust toolchain | kino 0.7.0 is a Rust (tokio/hyper) front-end; RubyGems ships precompiled `x86_64-linux`, `aarch64-linux`, both `-musl` variants, and `arm64-darwin` |
| R3 | **Two processes on one host**, `/ws*` routed to one, everything else to the other | `Monk::WebSocket::Server` is a standalone process (`lib/monk/websocket/server.rb:5`); the session cookie only rides the WS handshake automatically on the *same host* (`docs/deploying.md` §3) |
| R4 | **Five discrete `DB_*` env vars**, not a `DATABASE_URL` | `lib/monk/templates/postgres/config/persistence.rb` |
| R5 | **Postgres connections ≈ (Ractor pool size × instances) + 1 per bin/* script** | one memoized `PG::Connection` per Ractor, never shared (`lib/monk/persistence/pg.rb:8-15`) |
| R6 | **A migration step that is not the start command** | `bin/setup_db` is a separate script; nothing runs it on boot |
| R7 | **`REDIS_URL`, only if WebSocket fan-out crosses processes** | `bin/websocket_server` requires `monk/websocket/redis_fanout` only when the var is set; unset = in-process fan-out, which is correct for a single-instance deploy |
| R8 | **Outbound mail is the app's own job** | Monk has no mailer, deliberately (`docs/auth-sessions.md`: "Email delivery stays outside the framework") |
| R9 | **A writable `log/` directory** | `Monk::Log` appends to `log/<env>.log` in every environment (`lib/monk/log.rb:39-49`) — a read-only root filesystem breaks boot |
| R10 | **Env vars present in the main Ractor at boot** | `Monk::Settings` reads `ENV` at boot and seals the result shareable (`lib/monk/settings.rb`); platform-injected vars are fine, `.env` files are a dev-only convenience |

Two of these are the ones that actually decide the host: **R3** (one host,
two processes, a proxy in front) and **R2/R1** (Ruby 4.0 with a native
extension). Postgres and Redis are ordinary; SMTP is where the surprises
are (§4).

## 2. Blockers found while checking, before any host is chosen

These are repository findings, not host problems. They gate *any* deploy.

- **`gem "monk"` does not resolve to this framework.** The scaffolded
  `Gemfile` (`lib/monk/templates/base/Gemfile`) declares `gem "monk"`, but
  RubyGems' `monk` is the dormant 2009 Janowski/Martens gem (v0.0.7, last
  released 2009-09-24). A generated app therefore cannot `bundle install`
  on a build server today — it needs a `git:`/`path:` source until the
  rename `NOTES-V2.md` already flags actually happens. This is the single
  biggest obstacle to *every* option below, and it is entirely inside this
  repo.
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
lines of Caddyfile already in `docs/deploying.md`, and Caddy gets the TLS
certificate itself.

- **R1/R2**: `ruby:4.0-slim` base image, precompiled `kino` for the
  matching arch. No platform runtime to wait on.
- **R4**: set the five `DB_*` vars directly — no URL to parse, unlike
  every managed Postgres below.
- **R5**: Postgres' own `max_connections` is yours to raise.
- **R6**: `docker compose run --rm app bin/setup_db`.
- **R8**: the decisive one — **no outbound SMTP port blocking**, which is
  not true of any managed platform in this list (§4).
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

`docs/deploying.md`'s Render case still works, but three of its premises
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

The Fly case in `docs/deploying.md` is the one that has aged worst:

- **`fly postgres create` is deprecated.** Unmanaged Fly Postgres is no
  longer supported; `fly mpg` (Managed Postgres) replaces create/attach.
  It hands you a `DATABASE_URL`, so R4's open question in
  `docs/deploying.md` is now unavoidable rather than optional: either
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

Monk will not grow a mailer — `Monk::Auth.request_login` returns the raw
token and the app delivers it (`docs/auth-sessions.md`), and
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
   (`docs/auth-sessions.md`, `PLAN-AUTH.md` Phase 5). `Net::SMTP` is a
   bundled, not default, gem since Ruby 3.1 — it needs its own Gemfile
   line.
3. **Every send blocks a worker Ractor.** Monk has no job queue
   (`NOTES-V2.md` lists async jobs as a candidate), so an SMTP handshake
   inside `POST /auth/request` occupies one pool slot for its full
   round-trip. With a small pool that is a real capacity limit, and it
   argues for a fast HTTPS API call with a tight timeout over a
   multi-round-trip SMTP conversation.

**Port policy is the deciding factor between hosts**, and it is uniformly
hostile on managed platforms:

| Host | 25 | 465/587 |
|---|---|---|
| Own VPS | open | open |
| Railway | blocked | Pro plan and above only |
| Render | blocked (all plans) | paid instances only |
| Fly.io | blocked | support request in practice |

So: **on a VPS, real SMTP is fine. On a PaaS, prefer a provider's HTTPS
API** — same provider, same deliverability, no port policy. Free tiers as
of 2026: Brevo 9,000/month (300/day), Mailtrap ~4,000/month, Resend
3,000/month, Amazon SES 3,000/month for 12 months, Postmark 100/month
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
- **Either way, fix the two repo-side blockers first** (§2): `gem "monk"`
  resolving to a 2009 stranger, and the missing `bundle lock
  --add-platform` step. Nothing deploys cleanly until those are settled.

## 6. Open questions

1. Should `config/persistence.rb` accept `DATABASE_URL` (R4)? The answer
   is now clearly *yes* — Fly MPG only offers a URL, and Render/Railway
   both lead with one. `docs/deploying.md` raised this as an open
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
