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

Routes are matched by verb and path only: the query string is never part of matching, just parsed into `params`, and path params win over it. An unmatched request gets a plain `404`. How `params` reads a form or JSON body, `_method` for `patch`/`put`/`delete` from a form, and the `403` for another site's browser request are in [`forms.md`](forms.md): "Params", "Verbs other than POST" and "Requests from another site".

## REST resources — `resources` (experimental)

**Experimental — the one place this DSL departs from `verb(path) { block }`, in favor of a controller class plus a list of action symbols. Not settled as the right shape yet; may be reworked or removed rather than kept as-is.**

For a controller-style resource, `resources` registers the conventional seven routes at once, each dispatching to `controller.new(context).public_send(action)`:

```ruby
class OrdersController
  def initialize(context) = @context = context
  def index = @context.json(Order.where({}))
  def create = @context.json(Order.create(Order.from_form(@context.params[:order]))) # never params as they are: forms.md, "From form to row"
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

Inside a route block, `self` is a `Context` exposing `params`, `halt(status, body)`, `redirect(location)`, `json(data)`, `status`/`status=`, `headers`, `header(name)` (a request header), `flash` (see [`forms.md`](forms.md#flash)), `settings` (see [`settings.md`](settings.md)), `csrf_field` with auth (see [`forms.md`](forms.md#csrf-tokens-with-auth)) and — for HTML — `render`, `h`, `raw` and `asset_path` (see [`views.md`](views.md)). There are two ways to write a route block:

- **Zero-arg** (`get("/x") { params }`) — the common case: `self` is the request's `Context`, so its methods are called bare.
- **One-arg** (`get("/greet/:name") { |ctx| json(greeting: "hi #{ctx.params[:name]}") }`) — the same `Context`, also passed as the argument, for code that prefers it explicit.

`halt` short-circuits the handler and returns exactly the response given. `json` serializes the body and sets the JSON content-type header, using the current status (`200` by default, or whatever an `error` handler pre-sets it to). A route's return value is the body, sent with `status` (`self.status = 422` before returning). `redirect` goes only to this app — a path, or a URL on the request's `Host` — and raises `Monk::UnsafeRedirectError` for anything else, unless the app built the location itself and says so: `redirect(Monk::Storage.url(key), allow_other_host: true)` (see [`forms.md`](forms.md), "Redirects"). Ivars set on the `Context` (`@title = "Home"`) are visible to any template the route renders, and to its layout.

## Error handling

`error(SomeExceptionClass) { ... }` registers a handler for that exception class; unhandled exceptions get a default `500` JSON response. `error(404) { ... }` overrides the default not-found response. Handler blocks run with the same `Context` as routes:

```ruby
get("/protected") { halt 401, "nope" }

error(ArgumentError) { json(error: "bad input") }
error(404) { json(error: "not found") }
```
