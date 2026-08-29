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

- HTML templating
- Sessions / cookies
- Persistence
- Rack middleware composition

## Candidates (proposed features)

- ~~Package Monk as a gem (local gem for now, not published)~~ — done: `monk.gemspec` + `lib/monk/version.rb` (`Monk::VERSION = "0.1.0"`), MIT licensed, consumed via Bundler `path:` dependency (no RubyGems push). Verified against a throwaway sibling app at `../monk-consumer-test`. RubyGems already has an unrelated, dormant gem named `monk` — a rename will be needed before ever publishing.
- Database support, Postgres first
- Authentication and user sessions
- Caching system
- Async jobs
- Configuration system via environment variables
- WebSocket support, with session persistence

## Open questions

-

## Ideas
