# Monk

A minimalistic, Sinatra-style Ruby web framework designed to be fully `Ractor`-safe: every app it produces is a valid Rack 3 app that is also `Ractor.shareable?`, so it can be served in parallel across Ractor worker pools without silently losing that safety property. Named after Thelonious Monk.

Monk is Kino-agnostic — it's built on stdlib `Ractor` primitives only, with no runtime dependency on any particular server. [Kino](https://github.com/yaroslav/kino) is used as the reference/development server (see `bin/server`), since it's the most complete Ractor-native Rack server available, but any Ractor-aware Rack server, or a conventional one, can run a Monk app.

Requires **Ruby 4.0+**.

## Quick start

```
monk new my_app && cd my_app
bundle install
bin/server           # -> http://localhost:9292/hello
bundle exec rake test
```

`monk new` writes a working skeleton (an HTML home page, a `/hello` route, views/, public/) — see "Scaffolding a new project" below for what's in it, `--postgres`, and everything else `monk` on the command line does.

## Routing

`get`/`post`/`put`/`patch`/`delete` register routes with path params (`:id`) and a trailing wildcard/splat (`*`):

```ruby
class App < Monk::Base
  get("/hello") { "hello from monk" }

  get("/users/:id") { params[:id] }

  get("/files/*") { params[:splat] }

  get("/search") { json(query: params[:q]) } # GET /search?q=monk -> {"query":"monk"}
end
```

Routes are matched by verb and path only — the query string is never part of matching, just parsed into `params` (flat `key=value` pairs, no nested/array syntax) and merged with any JSON body and path params, with path params always winning on conflict. An unmatched request gets a plain `404`.

### REST resources — `resources` (experimental)

**Experimental — the one place this DSL departs from `verb(path) { block }`, in favor of a controller class plus a list of action symbols. Not settled as the right shape yet; may be reworked or removed rather than kept as-is.**

For a controller-style resource, `resources` registers the conventional seven routes at once, each dispatching to `controller.new(context).public_send(action)`:

```ruby
class OrdersController
  def initialize(context) = @context = context
  def index = @context.json(Order.where({}))
  def create = @context.json(Order.create(@context.params))
  # ...
end

resources("/orders", OrdersController) # every action
resources("/orders", OrdersController, :index, :create) # only these two
```

| action    | verb(s)      | path              |
|-----------|--------------|-------------------|
| `index`   | GET          | `/orders`         |
| `new`     | GET          | `/orders/new`     |
| `create`  | POST         | `/orders`         |
| `show`    | GET          | `/orders/:id`     |
| `edit`    | GET          | `/orders/:id/edit`|
| `update`  | PATCH, PUT   | `/orders/:id`     |
| `destroy` | DELETE       | `/orders/:id`     |

`resources` is built entirely on top of `get`/`post`/`put`/`patch`/`delete` — it doesn't change routing or dispatch, so it's a purely additive way to register several routes at once. Naming an action `resources` doesn't recognize raises `ArgumentError` immediately, rather than silently registering nothing.

## Context

Inside a route block, `self` is a `Context` exposing `params`, `halt(status, body)`, `json(data)`, `settings` (see "Settings" below) and — for HTML — `render`, `h`, `raw` and `asset_path` (see "Views" below). There are two ways to write a route block:

- **Zero-arg** (`get("/x") { params }`) — the common case; helpers are called bare via `instance_exec`.
- **One-arg** (`get("/greet/:name") { |ctx| json(greeting: "hi #{ctx.params[:name]}") }`) — explicit, useful when you want to pass a customized `Context` subclass around instead of relying on implicit `self`.

`halt` short-circuits the handler and returns exactly the response given. `json` serializes the body and sets the JSON content-type header, using the current status (`200` by default, or whatever an `error` handler pre-sets it to). Ivars set on the `Context` (`@title = "Home"`) are visible to any template the route renders, and to its layout.

## Error handling

`error(SomeExceptionClass) { ... }` registers a handler for that exception class; unhandled exceptions get a default `500` JSON response. `error(404) { ... }` overrides the default not-found response. Handler blocks run with the same `Context` as routes:

```ruby
get("/protected") { halt 401, "nope" }

error(ArgumentError) { json(error: "bad input") }
error(404) { json(error: "not found") }
```

## Boot and Ractor-shareability

`Monk::Base` subclasses must be **booted** before Kino (or any Ractor-aware server) can safely dispatch requests to them across parallel workers — this seals the route table and error handlers into a `Ractor.shareable?` structure. `Monk.boot(App)` does this eagerly, which is why `config.ru` uses `run Monk.boot(App)` rather than `run App` directly — booting eagerly (at server startup, not on the first request) is what lets tools like `kino --check` correctly report shareability before any traffic arrives.

If a route (or error handler) closes over a mutable local — the classic mistake:

```ruby
count = 0
get("/hits") { count += 1 }  # raises at boot: routes can't close over mutable state
```

`.freeze!` (which `Monk.boot` calls) raises `Monk::UnshareableRouteError` naming the offending route, rather than letting it fail silently or crash on the first live request.

## Settings — `Monk::Settings`

App-level configuration, declared once via `configure` and read back anywhere with `Monk::Settings[:key]` or, inside a route, `settings[:key]`:

```ruby
Monk::Settings.configure do
  required :api_key
  optional :port, default: "9292"
end

Monk::Settings[:api_key] # reads ENV["API_KEY"]
```

Each declared key reads from the uppercased env var of the same name, falling back to its default if optional. `MONK_ENV` is a built-in key every app gets for free — validated at boot against `development`/`test`/`staging`/`production` — and `Monk.env` returns a frozen `Environment` object with `.development?`/`.test?`/`.staging?`/`.production?` predicates.

`Monk.boot(App)` — the same step that freezes routes — checks every required key is present and freezes the resolved values into a `Ractor.shareable?` snapshot, so a worker Ractor can read `Settings[:key]` without `Ractor::IsolationError`. A missing required key raises `MissingSettingError` at boot rather than on the first request that needs it; `configure` after boot raises `SettingsFrozenError`; reading a key nobody declared raises `UnknownSettingError` either way.

`monk new` scaffolds ship a `config/settings.rb`, required at the top of `config.ru` before the app class body, that loads `dotenv` if the app's `Gemfile` has it uncommented — a missing `.env` file, or the gem not being bundled at all, is a harmless no-op; production deploys get their env vars from the hosting platform, not this file.

## Shared state — `Monk::StateRactor`

Route blocks can't safely close over ordinary mutable objects — that's what the error above is about. For state that genuinely needs to be shared and mutated across concurrent requests, use `Monk::StateRactor`, which wraps a value inside its own dedicated Ractor and serializes access to it:

```ruby
class App < Monk::Base
  hits = Monk::StateRactor.new(0)
  increment = Ractor.make_shareable(proc { |v| v + 1 })

  get("/hits") { json(hits: hits.update(&increment)) }
end
```

`#value` reads the current state; `#update { |current| new_value }` atomically transforms it. Both are synchronous calls under the hood, safe under real concurrent access from multiple workers.

One constraint worth knowing: the block passed to `#update` must be built where `self` is already `Ractor`-shareable (as above, at app-definition time, where `self` is the `App` class) — not written inline inside a route handler, where `self` is `Context` and deliberately not shareable. Predefine the block once (as `increment` above) and reference it from routes.

## Views — HTML with ERB

Templates live in `views/` (by convention; `views "app/views"` moves them)
and are compiled **once at boot**, in the main Ractor, into ordinary
methods — never at request time. That's not a performance preference, it's
what Ractor-safety leaves available: a worker can't hold a template cache
or install methods on a shared module. It also means a template with a
syntax error fails `Monk.boot`, naming the file and line, instead of
blowing up on a live request. See `docs/views.md` for the full design.

```ruby
class App < Monk::Base
  views  "views"          # default
  layout "layouts/app"    # optional default layout
  assets "public"         # default; `assets false` turns static serving off

  get("/") { @title = "Home"; render "index", posts: Post.where(published: true) }
end
```

```erb
<%# views/layouts/app.erb %>
<!doctype html>
<html>
  <head>
    <title><%= @title %></title>
    <link rel="stylesheet" href="<%= asset_path "/css/app.css" %>">
    <script type="module" src="<%= asset_path "/js/app.js" %>"></script>
  </head>
  <body><%= yield %></body>
</html>
```

```erb
<%# views/index.erb %>
<h1><%= @title %></h1>
<ul>
  <% locals[:posts].each do |post| -%>
    <%= render "posts/row", post: post -%>
  <% end -%>
</ul>
```

`render` **returns** the HTML rather than throwing the way `json` and
`halt` do — that's what makes a partial work: a template rendering another
template is the same call. A route block's return value is already the
response body, so `get("/") { render "index" }` needs nothing else, and
`content-type: text/html; charset=utf-8` is set for you.

**`<%= %>` HTML-escapes by default.** This is a deliberate break from stock
ERB, where it doesn't; `<%= raw(html) %>` opts out for a fragment you know
is safe, and `h(value)` escapes explicitly without escaping twice.

**Data reaches a template two ways, neither of which is machinery.** Ivars
set in the route (`@title`) are visible in the template *and* the layout,
because the route block, the template and the layout all execute with
`self` bound to the same `Context`. The `locals` hash passed to `render` is
the other, and it's what a partial rendered inside a loop wants. There's no
locals declaration syntax and no strict-locals checking — a local you
didn't pass reads as `nil`.

Layouts are just Ruby's `yield`: a compiled template is a real method, so
`<%= yield %>` in a layout receives the page's HTML. The default layout
wraps the outermost `render` of a request only, so partials aren't wrapped
again; `render "x", layout: false` skips it and `layout: "layouts/print"`
swaps it.

There is no JavaScript build step, and there won't be one — no bundler, no
transpiler, no `node_modules`. Use `<script type="module">`, relative
imports with real extensions between your own files, and an import map in
the layout for bare specifiers. An app that needs a bundler should run one
itself and drop the output into `public/`.

## Static assets

`public/` is walked at boot into a frozen manifest (body, content-type,
ETag) that worker Ractors read by reference. Assets are looked up **before**
routes, for `GET`/`HEAD` only — the position `Rack::Static` would occupy in
front of the app, so a catch-all splat route can't shadow a stylesheet. The
tradeoff: a route can't override a path that exists as a file.

Responses carry an `ETag` and answer `if-none-match` with a `304`.
`asset_path("/css/app.css")` stamps the URL with a content digest in
production, and a request carrying that stamp is served
`cache-control: public, max-age=31536000, immutable`; everything else gets
`must-revalidate`. No digested filenames, no build manifest.

In production a lookup is an exact-match fetch of a path enumerated at
boot, which makes path traversal structurally impossible rather than
defended against. In development (`MONK_ENV != "production"`) the body is
re-read from disk per request instead, so an edited `.css` or `.js` shows
up on the next refresh with no restart — and `asset_path` doesn't stamp,
since a boot-time digest would go stale the moment you save.

Putting nginx or a CDN in front of Monk is still the right call in
production; this exists so an app is complete on its own.

## Request logging — `Monk::Log`

Every request is appended as one line to `log/<env>.log` —
`log/development.log`, `log/test.log`, `log/production.log`, `log/staging.log`,
Rails-style — unconditionally, in every environment:

```
GET /hello -> 200 (1.2ms)
```

In development that same line is also echoed to `$stdout`, for a human
tailing the console; the file write happens either way. Each worker Ractor
lazily opens and keeps its own append-mode handle to the log file (a `File`
isn't `Ractor`-shareable the way `$stdout` is, so there's no single handle
every worker can share), and concurrent `O_APPEND` writers to the same path
need no extra locking — the same guarantee already relied on for several
worker Ractors sharing `$stdout`. `Monk::Log.root = "log"` is the only
knob; there's no per-route opt-out.

## Persistence — `Monk::Persistence::Pg`

Persistence is opt-in: `require "monk"` alone never loads it. Postgres is the
only backend today, via raw `pg` (Sequel was tried first and ruled out — it
raises `Ractor::IsolationError` from any non-main Ractor, with no
workaround; see `docs/persistence-ractor-connections.md`). Add `pg` to your
own `Gemfile` and:

```ruby
require "monk/persistence/pg"        # registry + raw connection access
require "monk/persistence/pg/model"  # CRUD sugar on top (needs the above)
```

### Setting up a database

Any reachable Postgres works — a local install or a container:

```
docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:16
```

Create the database and tables yourself (there's no migrations tooling);
`table_name` is never inferred, so it can be anything:

```
createdb monk_app
psql monk_app -c "CREATE TABLE widgets (id SERIAL PRIMARY KEY, name TEXT NOT NULL, quantity INTEGER NOT NULL DEFAULT 0)"
```

### Connecting

`register` a name once, with the same kwargs `PG.connect` takes, then use
that name everywhere — each Ractor lazily opens and memoizes its own
`PG::Connection` on first access (connections are never shared across
Ractors):

```ruby
Monk::Persistence::Pg.register(:main, host: "127.0.0.1", port: 5432, user: "postgres", password: "postgres", dbname: "monk_app")
```

Do this once at app boot (e.g. in `config.ru`, before `Monk.boot(App)`),
not inside a route.

### Models

A `Monk::Persistence::Pg::Model` subclass points at a registered `db_name`
and a `table_name`. It's deliberately not an ORM — no associations,
validations, callbacks, or dirty-tracking, and no live row objects: every
method takes or returns plain Symbol-keyed `Hash`es.

```ruby
class Widget < Monk::Persistence::Pg::Model
  self.db_name = :main
  self.table_name = "widgets"
end

Widget.create(name: "bolt", quantity: 10)     # => { id: 1, name: "bolt", quantity: 10 }
Widget.find(1)                                # => { id: 1, name: "bolt", quantity: 10 } or nil
Widget.find_all([1, 2, 99])                   # => [row1, row2, nil] -- one round trip, nil for a miss
Widget.where(name: "bolt")                    # => [{ id: 1, ... }, ...] -- AND only, still no OR
Widget.where(quantity: { gt: 5 })             # => comparison operators: gt/gte/lt/lte/ne
Widget.where(quantity: [5, 10])               # => IN -- matches any value in the Array
Widget.where({}, order: :id, limit: 20)       # => ORDER BY / LIMIT via a trailing options Hash
Widget.create_all([{ name: "bolt", quantity: 1 }, { name: "nut", quantity: 5 }])
                                               # => both rows, one INSERT -- every Hash needs the same columns
Widget.update(1, quantity: 20)                # => updated row, or nil if the id doesn't exist
Widget.delete(1)                              # => true/false, whether a row was actually deleted
```

`Monk.boot(App)` freezes every `Model` subclass's `db_name`/`table_name`
(and the connection registry itself) so they're readable from worker
Ractors — the same boot step that seals routes. This means `register` and
any `Model` classes must exist before `Monk.boot(App)` runs.

### Direct access

For anything `Model` doesn't cover, `checkout` yields the underlying
`PG::Connection` directly, serialized against sibling threads in the same
Ractor (a checkout that can't acquire the connection within
`timeout:` seconds, 5 by default, raises `Monk::PersistenceTimeoutError`):

```ruby
Monk::Persistence::Pg.checkout(:main) do |conn|
  conn.exec_params("SELECT * FROM widgets WHERE quantity > $1", [5])
end
```

`Monk::Persistence::Pg[:main]` returns that Ractor's memoized connection
without the checkout lock — use it for read-only, single-threaded-per-Ractor
access; prefer `checkout` whenever sibling threads might touch the same
connection concurrently.

## Migrations — `Monk::Persistence::Pg::Migrator`

Also opt-in (`require "monk/persistence/pg/migrator"`), and Postgres-only
like the rest of persistence. A migration is a pair of plain `.sql` files —
no DSL, no generator — named `<version>_<name>.up.sql` / `.down.sql`, with
`version` a sortable prefix (a timestamp works well: `20260831120000`):

```
db/migrate/20260831120000_create_widgets.up.sql
db/migrate/20260831120000_create_widgets.down.sql
```

```ruby
migrator = Monk::Persistence::Pg::Migrator.new(db_name: :main, dir: "db/migrate")

migrator.migrate!              # runs every pending .up.sql, in order, one transaction each
migrator.rollback!             # reverts the most recently applied migration
migrator.rollback!(steps: 3)   # reverts the 3 most recently applied
migrator.pending                # => not-yet-applied versions, ascending
migrator.applied                # => already-applied versions, in the order they ran
```

Applied versions are tracked in a `schema_migrations` table, created
automatically on first use. A failing statement rolls back just that
migration's transaction and halts the run — later pending migrations are
never attempted. Migrations never run implicitly (no hook into
`Monk.boot`/`.freeze!`); running them is an explicit step your app invokes
itself, e.g. a `bin/migrate` script — see `PLAN-MIGRATIONS.md` for the full
design and phase-by-phase plan.

## Auth & sessions — `Monk::Auth`

Passwordless token auth, opt-in (`require "monk"` never loads it) and built
on `Monk::Persistence::Pg` — not just an integration, a hard dependency:
`Monk::Auth::LoginToken`/`Session` are themselves `Pg::Model` subclasses, so
`require "monk/auth"` always needs the `pg` gem and a registered Postgres
connection, whether or not your app uses persistence for anything else.
`monk new my_app --auth` scaffolds all of it in one step (implying
`--postgres`): `config/auth.rb` and a migration creating the tables below —
see "Scaffolding a new project" further down.

```ruby
require "monk/auth"

Monk::Auth.configure(
  db_name: :main, secret: ENV.fetch("AUTH_SECRET"),
  login_ttl: 600, session_ttl: 1_209_600, redirect_allowlist: ["/dashboard"],
)

class App < Monk::Base
  post("/auth/request") { json(token: Monk::Auth.request_login(params[:email])) } # email this token yourself -- Monk doesn't

  get("/auth/callback/:token") do
    session = Monk::Auth.redeem(params[:token])
    halt(401) unless session
    json(token: session[:token], expires_at: session[:expires_at])
  end

  get("/me") { json(subject: require_user!) } # halts 401 automatically if unauthenticated
end
```

Two Postgres tables back this — `login_tokens` (single-use, short-lived)
and `sessions` (multi-use, long-lived). `monk new --auth` scaffolds a
migration for both; otherwise create them yourself the same way persistence
tables aren't generated either — schema in `docs/auth-sessions.md`.

Both an `Authorization: Bearer <token>` header and a `session_token`
cookie work identically via `current_subject`/`require_user!`. For
browsers, `set_session_cookie(session)` sets that cookie (plus a readable
`csrf_token` one) instead of returning the token as JSON, and
`require_csrf!` guards state-changing routes — a no-op for Bearer
requests, since a forged cross-origin request has no way to set that
header. `Monk::Auth.revoke(token)` / `.revoke_all(subject)` invalidate
sessions; `.sweep!` deletes expired rows. Full design and phase-by-phase
build: `docs/auth-sessions.md` / `PLAN-AUTH.md`.

## WebSocket — `Monk::WebSocket`

A hand-rolled RFC 6455 server, opt-in (`require "monk/websocket"`),
running as its **own process on its own port** — Kino has no hijack
support, so this never shares a process with your HTTP app
(`docs/websocket.md`). Each connection gets its own dedicated Ractor:

```ruby
require "monk/websocket"

# The handler must be built where self is Ractor-shareable -- a module
# body, not a script's own top level (self there is the main object,
# which isn't shareable) -- same constraint Monk::StateRactor#update has.
module Chat
  REGISTRY = Monk::WebSocket::Registry.new

  HANDLER = proc do |connection|
    connection.subscribe(REGISTRY, :chat)
    loop do
      message = connection.read # nil on disconnect/close -- exits the loop
      break unless message

      REGISTRY.broadcast(:chat, "#{connection.subject}: #{message}")
    end
  end
end

server = Monk::WebSocket::Server.new(
  port: 9293, authenticate: true, allowed_origins: ["https://example.com"],
  ping_interval: 30, reverify_interval: 60,
)
server.run(&Chat::HANDLER)
```

`authenticate: true` reuses `Monk::Auth` unmodified — the same
`Authorization: Bearer` header or `session_token` cookie the HTTP side
accepts, verified before the `101` response is sent; a missing or invalid
credential gets a `401`. `allowed_origins:` guards the cookie path
specifically against Cross-Site WebSocket Hijacking (a Bearer connection
has no `Origin` header to forge). `ping_interval:` (seconds, off by
default) sends a server-initiated ping on that cadence — a spec-compliant
client answers it with a pong automatically, no app code involved either
side, which is what actually defeats an idle reverse-proxy timeout: a
connection that only ever answers a client's own pings stays vulnerable
whenever the client is a browser, since browser JavaScript has no API to
send WS pings at all. `reverify_interval:` (seconds, off by default,
requires `authenticate: true`) re-runs `Monk::Auth.verify` against the
same credential on that cadence and closes the socket the moment it comes
back nil — without it, a session revoked or expired after the handshake
leaves the connection live indefinitely, since `authenticate: true` only
checks the credential once, at connect time. A reverse proxy in front
routes `/ws` to this process and everything else to Kino, on the **same
host** — see `docs/deploying.md` for a worked Caddy/nginx example. Full
design and phase-by-phase build: `docs/websocket.md` / `PLAN-WEBSOCKET.md`.

## Scaffolding a new project — `monk new`

```
monk new my_app              # Gemfile, config.ru, .ruby-version, bin/server, views/, public/
monk new my_app --postgres   # + config/persistence.rb, bin/console, bin/setup_db, bin/migrate, db/migrate/
monk new my_app --auth       # + --postgres, above, plus config/auth.rb and a migration for
                              #   login_tokens/sessions (needs AUTH_SECRET set before boot)
```

Writes a fresh project directory from static templates (never overwrites
an existing directory — `monk new` refuses if `my_app` already exists) and
prints the next manual step (`bundle install`); it never runs `bundle
install`, `git init`, or anything else on your behalf. `--postgres` adds
exactly the persistence/migrations wiring documented above, ready for you
to add your own `db/migrate/*.sql` files and `Model` subclasses.

`--auth` always implies `--postgres` — `Monk::Auth` has no path that avoids
Postgres (see "Auth & sessions" above), so there's no flag combination that
scaffolds Auth without also scaffolding persistence underneath it. Plain
`monk new my_app` (no flags) and `--postgres` alone both leave Auth
unconfigured; `require "monk/auth"` still works if you wire it by hand, but
nothing generated by those two commands does it for you. `Monk::WebSocket`
needs no flag either way — `authenticate: true` is a constructor kwarg you
pass yourself, not something scaffolding turns on.

The base skeleton is a working HTML page, not a bare JSON route: a layout
and an index template under `views/`, and a stylesheet and an ES-module
entry point under `public/` (see "Views" and "Static assets" above).

### Adding Postgres or Auth to an existing app

`monk new`'s flags only apply at creation time — there's no `monk add`
command. Retrofitting an app you already scaffolded plain (or wrote by
hand) means adding the same files `--postgres`/`--auth` would have
written, by hand:

**Postgres:**

1. Add `gem "pg"` to your `Gemfile` (and `gem "irb"` if you want
   `bin/console`), then `bundle install`.
2. Create `config/persistence.rb` — same content as the "Connecting"
   example under "Persistence" above.
3. `require_relative "config/persistence"` near the top of `config.ru`,
   before `Monk.boot(App)` — `register` and any `Model` classes must exist
   before boot (see "Persistence" → "Models").
4. `mkdir -p db/migrate`, and add `bin/setup_db`/`bin/migrate` scripts if
   you want migrations (copy the pattern from "Migrations" above, or lift
   `bin/setup_db`/`bin/migrate`/`bin/console` verbatim from a
   `monk new --postgres` app — they're plain scripts, not templated).
5. Create the database and register/migrate against it (see "Setting up a
   database" under "Persistence").

**Auth** (do the Postgres steps first — there's no way around them, see
"Auth & sessions" above):

1. Create `config/auth.rb`:
   ```ruby
   require "monk"
   require "monk/auth"
   require_relative "persistence"

   Monk::Auth.configure(
     db_name: :primary, secret: ENV.fetch("AUTH_SECRET"),
     login_ttl: 600, session_ttl: 1_209_600, redirect_allowlist: [],
   )
   ```
2. `require_relative "config/auth"` in `config.ru`, before `Monk.boot(App)`.
3. Add a migration creating `login_tokens`/`sessions` — schema under "Auth
   & sessions" above. Give it a version that sorts after any migrations you
   already have (a timestamp, e.g. `20260907120000_create_auth_tables`) —
   don't reuse `00000000000001`, which `monk new --auth` only picks because
   it assumes it's the first migration in a fresh project.
4. Set `AUTH_SECRET` (e.g. via `.env`, loaded by the `config/settings.rb`
   every skeleton already ships) and run your migration script.

## Working on this repo

This is the framework's own source checkout — `config.ru` at the repo root
is a demo app exercising most of the features above, not a project
scaffolded with `monk new`. To run its test suite and its demo server:

```
bundle install
bundle exec rake test          # Minitest, calling App.call(env) directly
                                # against hand-built Rack env hashes -- see
                                # test/test_helper.rb; no Rack::Test dependency
bin/server                     # serves config.ru via kino, default (ractor) mode
bin/server --mode threaded     # threaded mode, useful as a stopgap if something isn't booting cleanly
bin/server --check             # reports Ractor-shareability without serving
PORT=9999 bin/server           # change the port (default 9293)
```

### Running in Docker

```
docker build -t monk .
docker run --rm -p 9293:9293 monk
```

This serves `config.ru` via `bin/server`, bound to `0.0.0.0` so it's reachable from outside the container (kino's own default, `127.0.0.1`, wouldn't be). Change the published port with `-p <host-port>:9293`, e.g. `docker run --rm -p 9999:9293 monk`.

## Status

v1 is done, built out gradually with TDD — see `PLAN.md` for its phase-by-phase plan and `CONTEXT.md` / `docs/adr/` for the domain vocabulary and key architectural decisions it left behind. v1 deliberately left out HTML templating, sessions/cookies, persistence, and Rack middleware composition.

Monk is now on v2, worked one candidate at a time, agile-style, rather than against a fixed upfront plan. The living list of candidates and their status is [issue #19](https://github.com/matteofuzz/monk/issues/19) (seeded from `NOTES-V2.md`); each candidate gets its own plan doc once work on it actually starts.

Candidates done so far, each with its own design doc and phase-by-phase
plan: **persistence** (`Monk::Persistence::Pg`, raw `pg`, `PLAN-PERSISTENCE.md`),
**migrations** (`Monk::Persistence::Pg::Migrator`, plain `.sql` up/down
pairs, `PLAN-MIGRATIONS.md`), **HTML templating** (ERB views and static
asset serving, both compiled/enumerated at boot and frozen — SCSS was
explored and deliberately left out, plain CSS only — `docs/views.md` /
`PLAN-VIEWS.md`), **auth & sessions** (passwordless token auth over
`Authorization: Bearer` and cookie+CSRF, `docs/auth-sessions.md` /
`PLAN-AUTH.md`), and **WebSocket** (a hand-rolled RFC 6455 server as its
own process, reusing `Monk::Auth` for the handshake, `docs/websocket.md` /
`PLAN-WEBSOCKET.md`) — all done as of 2026-09-05.
