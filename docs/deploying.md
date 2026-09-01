# Deploying a Monk app

Example deployment cases for an app scaffolded with `monk new --postgres`
(`Gemfile`, `config.ru`, `config/persistence.rb`, `bin/setup_db`,
`bin/migrate`, `bin/console`, `db/migrate/`). Both cases below assume that
scaffold as the starting point.

Neither case changes anything in this repo (`monk` itself) — they describe
how a generated app deploys.

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

## Open question

`config/persistence.rb` as scaffolded today only reads discrete `DB_*`
vars. Both Render and Fly can supply those directly, but Fly's default
Postgres attach flow hands you a `DATABASE_URL` instead — worth deciding
whether the scaffold should support `DATABASE_URL` out of the box (a small
`URI.parse` change) so `fly postgres attach` works with zero manual
wiring.
