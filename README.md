# Monk

A minimalistic, Sinatra-style Ruby web framework designed to be fully `Ractor`-safe: every app it produces is a valid Rack 3 app that is also `Ractor.shareable?`, so it can be served in parallel across Ractor worker pools without silently losing that safety property. Named after Thelonious Monk.

Monk is Kino-agnostic — it's built on stdlib `Ractor` primitives only, with no runtime dependency on any particular server. [Kino](https://github.com/yaroslav/kino) is used as the reference/development server (see `bin/server`), since it's the most complete Ractor-native Rack server available, but any Ractor-aware Rack server, or a conventional one, can run a Monk app.

Requires **Ruby 4.0+**.

## Quick start

```ruby
require "monk"

class App < Monk::Base
  get("/hello") { "hello from monk" }

  get("/users/:id") { params[:id] }

  get("/files/*") { params[:splat] }

  get("/greet/:name") { |ctx| json(greeting: "hi #{ctx.params[:name]}") }

  get("/protected") { halt 401, "nope" }

  error(ArgumentError) { json(error: "bad input") }
  error(404) { json(error: "not found") }
end

run Monk.boot(App)
```

Save that as `config.ru` and run it with any Rack server (or `bin/server` in this repo, which runs it under Kino).

## Scaffolding a new project — `monk new`

```
monk new my_app              # Gemfile, config.ru, .ruby-version, views/, public/
monk new my_app --postgres   # + config/persistence.rb, bin/console, bin/setup_db, bin/migrate, db/migrate/
```

Writes a fresh project directory from static templates (never overwrites
an existing directory — `monk new` refuses if `my_app` already exists) and
prints the next manual step (`bundle install`); it never runs `bundle
install`, `git init`, or anything else on your behalf. `--postgres` adds
exactly the persistence/migrations wiring documented below, ready for you
to add your own `db/migrate/*.sql` files and `Model` subclasses.

The base skeleton is a working HTML page, not a bare JSON route: a layout
and an index template under `views/`, and a stylesheet and an ES-module
entry point under `public/` (see "Views" and "Static assets" below).

## Routing

`get`/`post`/`put`/`patch`/`delete` register routes with path params (`:id`) and a trailing wildcard/splat (`*`). Routes are matched by verb and path; an unmatched request gets a plain `404`.

## Context

Inside a route block, `self` is a `Context` exposing `params`, `halt(status, body)`, `json(data)`, and — for HTML — `render`, `h`, `raw` and `asset_path` (see "Views" below). There are two ways to write a route block:

- **Zero-arg** (`get("/x") { params }`) — the common case; helpers are called bare via `instance_exec`.
- **One-arg** (`get("/x") { |ctx| ctx.params }`) — explicit, useful when you want to pass a customized `Context` subclass around instead of relying on implicit `self`.

`halt` short-circuits the handler and returns exactly the response given. `json` serializes the body and sets the JSON content-type header, using the current status (`200` by default, or whatever an `error` handler pre-sets it to). Ivars set on the `Context` (`@title = "Home"`) are visible to any template the route renders, and to its layout.

## Error handling

`error(SomeExceptionClass) { ... }` registers a handler for that exception class; unhandled exceptions get a default `500` JSON response. `error(404) { ... }` overrides the default not-found response. Handler blocks run with the same `Context` as routes.

## Boot and Ractor-shareability

`Monk::Base` subclasses must be **booted** before Kino (or any Ractor-aware server) can safely dispatch requests to them across parallel workers — this seals the route table and error handlers into a `Ractor.shareable?` structure. `Monk.boot(App)` does this eagerly, which is why `config.ru` uses `run Monk.boot(App)` rather than `run App` directly — booting eagerly (at server startup, not on the first request) is what lets tools like `kino --check` correctly report shareability before any traffic arrives.

If a route (or error handler) closes over a mutable local — the classic mistake:

```ruby
count = 0
get("/hits") { count += 1 }  # raises at boot: routes can't close over mutable state
```

`.freeze!` (which `Monk.boot` calls) raises `Monk::UnshareableRouteError` naming the offending route, rather than letting it fail silently or crash on the first live request.

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
Widget.where(name: "bolt")                    # => [{ id: 1, ... }, ...] -- equality + AND only
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

## Running locally

```
bundle install
bin/server                    # serves config.ru via kino, default (ractor) mode
bin/server --mode threaded    # threaded mode, useful as a stopgap if something isn't booting cleanly
bin/server --check            # reports Ractor-shareability without serving
PORT=9999 bin/server          # change the port (default 9293)
```

## Running in Docker

```
docker build -t monk .
docker run --rm -p 9293:9293 monk
```

This serves `config.ru` via `bin/server`, bound to `0.0.0.0` so it's reachable from outside the container (kino's own default, `127.0.0.1`, wouldn't be). Change the published port with `-p <host-port>:9293`, e.g. `docker run --rm -p 9999:9293 monk`.

## Development

```
bundle install
bundle exec rake test
```

Tests are Minitest, calling `App.call(env)` directly against hand-built Rack env hashes (see `test/test_helper.rb`) — no Rack::Test dependency.

## Status

v1 is done, built out gradually with TDD — see `PLAN.md` for its phase-by-phase plan and `CONTEXT.md` / `docs/adr/` for the domain vocabulary and key architectural decisions it left behind. v1 deliberately left out HTML templating, sessions/cookies, persistence, and Rack middleware composition.

Monk is now on v2, worked one candidate at a time, agile-style, rather than against a fixed upfront plan. The living list of candidates and their status is [issue #19](https://github.com/matteofuzz/monk/issues/19) (seeded from `NOTES-V2.md`); each candidate gets its own plan doc once work on it actually starts — e.g. `PLAN-PERSISTENCE.md` for persistence, the first candidate done.

HTML templating is done as of 2026-09-05: ERB views and static asset
serving, both compiled/enumerated at boot and frozen (`docs/views.md` for
the design and the spikes behind it, `PLAN-VIEWS.md` for the phase-by-phase
plan). SCSS was explored in the same pass and deliberately left out for
now — plain CSS only.
