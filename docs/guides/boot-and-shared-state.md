# Boot and Ractor-shareability

`Monk::Base` subclasses must be **booted** before Kino (or any Ractor-aware server) can safely dispatch requests to them across parallel workers — this seals the route table and error handlers into a `Ractor.shareable?` structure. `Monk.boot(App)` does this eagerly, which is why `config.ru` uses `run Monk.boot(App)` rather than `run App` directly — booting eagerly (at server startup, not on the first request) is what lets tools like `kino --check` correctly report shareability before any traffic arrives.

If a route (or error handler) closes over a mutable local — the classic mistake:

```ruby
count = 0
get("/hits") { count += 1 }  # raises at boot: routes can't close over mutable state
```

`.freeze!` (which `Monk.boot` calls) raises `Monk::UnshareableRouteError` naming the offending route, rather than letting it fail silently or crash on the first live request.

# Shared state — `Monk::StateRactor`

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
