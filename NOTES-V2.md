# Monk V2 — Notes

Scratch notes for ideas to consider once V1 is settled. Not a plan yet — see `PLAN.md` for that once V2 work actually starts.

## Known limitations (v1)

Grounded in the current `lib/monk` implementation, not just the README's explicit scope cuts (those are listed separately below).

- **No query string / body parsing** — `params` only ever comes from path segments (`:id`, splat). GET query strings and POST form/JSON bodies aren't parsed into `params` at all.
- **Linear route matching** — `find_route` scans every registered route in registration order for every request; no compiled/indexed lookup, fine for small route tables but O(n) per request.
- **Splat is trailing-only** — a wildcard is only recognized as the last path segment (`route_segments.last == "*"`); no mid-path splats, no regex routes.
- **No custom response headers** — `dispatch`, `halt`, and the default 500 response all hardcode `{}` or a single content-type header; a route/handler has no way to add e.g. caching, CORS, or custom headers.
- **Error handler matching is first-registered-wins, not most-specific** — if two `error` handlers both match an exception via `is_a?`, whichever was registered first wins regardless of subclass specificity.
- **Only `StandardError` is rescued** — exceptions outside that hierarchy aren't caught by user `error` handlers.
- **`error 404` handlers can't see route params** — `Context.new({}, status: 404)` is always built with empty params, so a 404 handler can't customize behavior per attempted route.
- **No middleware/composition layer** — Rack `use` isn't supported; cross-cutting concerns (auth, gzip, CORS) must be hand-rolled inside route/error blocks.
- **`StateRactor` has no shutdown/cleanup path** — the underlying Ractor runs for the process lifetime once created; no way to stop it (relevant for tests or short-lived apps).
- **`StateRactor#update` fully serializes on slow blocks** — a slow/blocking update block blocks every other request waiting on that same `StateRactor`; no timeout, no async variant.
- **No cross-`StateRactor` atomicity** — updates spanning two different `StateRactor` instances aren't transactional together.
- **Logging is fixed** — stdout only, hardcoded `ENV["MONK_ENV"] == "production"` check to disable it; no pluggable logger, level, or structured format.
- **No streaming/chunked responses** — the body is always a single-element array wrapping one string.

## Candidates (from v1's deliberate scope cuts)

- HTML templating — design proposed 2026-09-05, widened to the whole
  server-rendered surface (ERB compiled at boot into methods on a shareable
  module, escape-by-default; a boot-built frozen manifest for static CSS/JS;
  SCSS opt-in and boot-only, because `sass-embedded` is the third gem found
  to raise `Ractor::IsolationError` from a worker; no JS build step, ever):
  `docs/views.md` + `PLAN-VIEWS.md`. Six spikes back it, but they ran on
  Ruby 3.3.6 rather than 4.0.6 — `PLAN-VIEWS.md` Phase 0 re-measures the
  Ractor-flavored ones before anything is built on them. Not implemented.
- Sessions / cookies
- Persistence
- Rack middleware composition

## Candidates (proposed features)

- ~~Package Monk as a gem (local gem for now, not published)~~ — done: `monk.gemspec` + `lib/monk/version.rb` (`Monk::VERSION = "0.1.0"`), MIT licensed, consumed via Bundler `path:` dependency (no RubyGems push). Verified against a throwaway sibling app at `../monk-consumer-test`. RubyGems already has an unrelated, dormant gem named `monk` — a rename will be needed before ever publishing.
- Database support, Postgres first
- Authentication and user sessions — design finalized 2026-09-01 across
  all three transports (passwordless, TTL'd tokens; `Authorization:
  Bearer` for API/S2S, an `HttpOnly` cookie + double-submit CSRF for
  browsers, and identity for `Monk::WebSocket` connections resolved via
  the same cookie, gated by `Origin` validation): `docs/auth-sessions.md` +
  `PLAN-AUTH.md`. Not implemented; needs `Context#env` and a boot-frozen
  config first.
- Caching system
- Async jobs
- Configuration system via environment variables
- WebSocket support, with session persistence — design proposed (separate
  process alongside Kino, not an in-Kino feature; Kino confirmed
  architecturally unable to expose a raw socket, `rack.hijack` included).
  Phase 0 spike (2026-09-01) found both candidate WebSocket gems fail
  under a real Ractor for unrelated reasons; a follow-up end-to-end spike
  the same day proved the hand-rolled alternative (RFC 6455 over a real
  `TCPServer`, one dedicated Ractor per connection) works correctly,
  including true concurrency and isolated per-connection failure:
  `docs/websocket.md`. Implementation plan: `PLAN-WEBSOCKET.md`. Not
  implemented yet.

## Open questions

-

## Ideas

- A lightweight layering convention, echoing Rails' MVC but deliberately simpler: a clean separation between business logic, data rendering, and the persistence layer, without pulling in a full ActiveRecord/ActionView-style stack. Needs its own design pass (naming, how it plugs into `Context`/routes, how it relates to the Postgres-support and templating candidates above) before it becomes a concrete feature.
