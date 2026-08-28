# Monk v1 — TDD Implementation Plan

This plan develops Monk in small, gradual, red → green cycles. Each numbered step is one vertical slice: one failing test against its seam, then the minimum code to pass it. Refactoring is a separate pass per item, not folded into the loop itself.

See `CONTEXT.md` for domain vocabulary (`StateRactor`, `Context`, `Boot`) and `docs/adr/` for the architectural decisions this plan builds on.

## Seams

Four seams cover the whole v1 surface:

- **Seam A — `App.call(env)`** (the Rack boundary): routing, params, `halt`, `json`, error handling — everything observable as an HTTP request/response.
- **Seam B — `App.freeze!`** (the `Boot` primitive): shareability sealing and fail-fast validation, tested directly against its own return value / raised errors, not through HTTP.
- **Seam C — `Monk::StateRactor`'s own public API**: a standalone primitive, tested against its own interface, not as an internal collaborator of an app.
- **Seam D — real concurrent Ractor integration**: multiple Ractors actually calling into `App.call(env)` and `StateRactor` at once — the only place we prove the premise of the whole project holds under real parallelism, not just in a single Ractor.

## Phase 1 — Routing core (Seam A)

1. `get("/x") { "hi" }` → `GET /x` returns `200` with body `"hi"`
2. Unmatched path → `404`
3. `post`/`put`/`patch`/`delete` route correctly by verb
4. `/users/:id` → `params[:id]` reflects the captured segment
5. A wildcard/splat segment is captured and reachable via `params`

## Phase 2 — Context & dual dispatch (Seam A)

6. Zero-arg route block: bare `params` resolves via `instance_exec`
7. One-arg route block: `|ctx|` receives the same data explicitly
8. `halt(status, body)` short-circuits the handler and returns exactly that response
9. `json(hash)` serializes the body and sets the JSON content-type header

## Phase 3 — Error handling (Seam A)

10. An unhandled exception in a route yields a default `500` JSON error response
11. A registered `error SomeException` handler overrides the default for that exception class
12. A registered `error 404` handler overrides the default not-found response

## Phase 4 — Boot / shareability (Seam B)

13. `App.freeze!` on a well-behaved app returns/produces something `Ractor.shareable?` reports `true` for
14. `App.freeze!` raises a precise error (naming the offending route) when a route closes over a mutable local
15. The Rack entrypoint helper invokes `.freeze!` exactly once, automatically, for both `run App` and `run App.new`

## Phase 5 — StateRactor (Seam C)

16. `Monk::StateRactor.new(0)` constructed and reachable — establishes its concrete message API test-first (this is the one open API-shape decision left; the first test fixes it)
17. A `StateRactor` instance itself is `Ractor.shareable?`
18. Sequential calls mutate and return state correctly, one at a time

## Phase 6 — Real Ractor integration (Seam D)

19. Multiple real Ractors calling `App.call(env)` concurrently for a stateless route all succeed with correct, independent responses
20. Multiple real Ractors hammering one shared `StateRactor` concurrently never lose an update (race-safety proof)
21. Manual smoke test (not CI, given Kino's experimental/Ruby-4.0 status): boot the app under actual Kino and hit it with real HTTP requests — documented as a verification step, not an automated cycle
