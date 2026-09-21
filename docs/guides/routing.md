# Routing

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

## REST resources — `resources` (experimental)

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

# Context

Inside a route block, `self` is a `Context` exposing `params`, `halt(status, body)`, `json(data)`, `settings` (see [`settings.md`](settings.md)) and — for HTML — `render`, `h`, `raw` and `asset_path` (see [`views.md`](views.md)). There are two ways to write a route block:

- **Zero-arg** (`get("/x") { params }`) — the common case; helpers are called bare via `instance_exec`.
- **One-arg** (`get("/greet/:name") { |ctx| json(greeting: "hi #{ctx.params[:name]}") }`) — explicit, useful when you want to pass a customized `Context` subclass around instead of relying on implicit `self`.

`halt` short-circuits the handler and returns exactly the response given. `json` serializes the body and sets the JSON content-type header, using the current status (`200` by default, or whatever an `error` handler pre-sets it to). Ivars set on the `Context` (`@title = "Home"`) are visible to any template the route renders, and to its layout.

# Error handling

`error(SomeExceptionClass) { ... }` registers a handler for that exception class; unhandled exceptions get a default `500` JSON response. `error(404) { ... }` overrides the default not-found response. Handler blocks run with the same `Context` as routes:

```ruby
get("/protected") { halt 401, "nope" }

error(ArgumentError) { json(error: "bad input") }
error(404) { json(error: "not found") }
```
