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

## Routing

`get`/`post`/`put`/`patch`/`delete` register routes with path params (`:id`) and a trailing wildcard/splat (`*`). Routes are matched by verb and path; an unmatched request gets a plain `404`.

## Context

Inside a route block, `self` is a `Context` exposing `params`, `halt(status, body)`, and `json(data)`. There are two ways to write a route block:

- **Zero-arg** (`get("/x") { params }`) — the common case; helpers are called bare via `instance_exec`.
- **One-arg** (`get("/x") { |ctx| ctx.params }`) — explicit, useful when you want to pass a customized `Context` subclass around instead of relying on implicit `self`.

`halt` short-circuits the handler and returns exactly the response given. `json` serializes the body and sets the JSON content-type header, using the current status (`200` by default, or whatever an `error` handler pre-sets it to).

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

This is v1, built out gradually with TDD — see `PLAN.md` for the phase-by-phase plan and `CONTEXT.md` / `docs/adr/` for the domain vocabulary and key architectural decisions. Deliberately out of scope for v1: HTML templating, sessions/cookies, persistence, and Rack middleware composition.
