# Monk views & assets — implementation plan

Branch: `claude/html-css-js-erb-render-j9xyef` — nothing in this plan is
implemented yet. Companion doc: `docs/views.md` (why everything compiles at
boot, the six spikes, the API this plan builds out, the rejected
alternatives).

Like `PLAN.md`, this develops in small, gradual, red → green cycles. Each
numbered step is one vertical slice: one failing test against its seam,
then the minimum code to pass it. Phase 0 is the exception, per
`PLAN-PERSISTENCE.md`'s and `PLAN-WEBSOCKET.md`'s precedent — it's a spike,
not TDD, and it gates everything below.

Every phase runs on Monk's target Ruby, 4.0.6 (`.ruby-version`). The spikes
behind `docs/views.md` ran on 3.3.6 because that was what the exploring
session had; that is exactly the situation `PLAN-WEBSOCKET.md`'s rule
("Ractor behavior is measured on 4.x directly, never inferred from a 3.x
result") exists for, so Phase 0 re-measures the Ractor-flavored ones before
any of it is trusted.

## Phase 0 — Re-run the spikes on 4.0.6 (gates everything below)

Not TDD. Throwaway scripts, outside the repo, on 4.0.6. Four questions,
each with a decision attached:

1. **Does a compiled template method, defined on a module in the main
   Ractor, render correctly when called from a worker Ractor?** If no, the
   whole compile-to-method design is dead and the fallback is
   eval-per-request inside the worker (spike 5's dev path, promoted to the
   only path) — much slower, so measure it before deciding.
2. **Is the frozen asset manifest readable from a worker Ractor,** and does
   `Ractor.make_shareable` accept a nested hash of binary strings? If no,
   assets must be read from disk per request in every mode, and the
   manifest degrades to metadata only.
3. **Does `sass-embedded` still fail inside a worker Ractor?** Expected yes
   (`Ractor::IsolationError`, third gem to do it). A surprising *pass*
   changes nothing about the design — boot-time compilation is still what
   we want — but it should be recorded in `docs/ractor.md`.
4. **What actually happens when a first request hits an app that was never
   `Monk.boot`ed, in a worker Ractor,** now that `Base.call`'s lazy
   `freeze!` would drag template compilation in with it? Whatever the
   answer, it decides whether Phase 1 needs a guard that raises a clear
   `Monk::NotBootedError` instead of whatever Ruby produces.

Record results in `docs/views.md` (replacing the provisional numbers) and
any new general finding in `docs/ractor.md`.

## Decisions locked in before Phase 1

From `docs/views.md`, so the TDD loop isn't relitigating them:

- Templates compile at `Boot`, in the main Ractor, never at request time.
- `<%= %>` escapes; `<%= raw(x) %>` doesn't. `Raw < String` with
  `#to_s` → `self`.
- Locals are declared by the template: `<%# locals: (title:, badge: nil) %>`,
  compiled into keyword parameters. No declaration means no locals accepted.
  The declaration line is blanked, not removed, so line numbers survive.
- `render` returns a `Raw` and sets `content-type: text/html; charset=utf-8`
  unless already set; it does not `throw`.
- `layout:` is a reserved keyword of `render`; a template declaring a local
  named `layout` is a boot error.
- Assets are looked up before routes, for `GET`/`HEAD` only.
- SCSS is opt-in (`require "monk/views/scss"`), compiles at boot into the
  same manifest, and closes its compiler afterwards.
- Stdlib only for views and assets (`erb`, `cgi/escape`, `digest`).
  `sass-embedded` is the app's dependency, never Monk's.

## Seams

- **Seam V — `Monk::Views` compilation API**: source in, compiled method +
  registry entry out. Escaping, locals signatures, layouts, boot-time
  errors — tested directly, no HTTP.
- **Seam W — `App.call(env)` for HTML**: rendering observed through the Rack
  boundary, the way `test/routing_test.rb` already works.
- **Seam X — `App.call(env)` for assets**: manifest hits, content types,
  `ETag`/`304`, dev-mode disk reads, precedence against routes.
- **Seam Y — `Monk::Views::Scss` registration**: registered source →
  manifest entry, tested against the manifest, not over HTTP.
- **Seam Z — real Ractor integration**: concurrent renders and asset reads
  from multiple real Ractors, matching `test/ractor_integration_test.rb`.

## Phase 1 — Compile and render one template (Seam V)

1. `Monk::Views.compile("index", "<p>hi</p>", "views/index.erb")` registers
   the template and `Context#render("index")` returns `"<p>hi</p>"`
2. `<%= %>` interpolation of a plain value works, and the result is a
   `Monk::Views::Raw`
3. `<%= %>` HTML-escapes by default (`"<script>"` → `&lt;script&gt;`)
4. `raw("<em>x</em>")` passes through unescaped, and `h` is available
   explicitly
5. `<% %>` control flow (a loop) emits once per iteration; `-%>` trims the
   trailing newline
6. A template rendering another template (`<%= render "row" %>`) nests
   correctly, with no double-escaping

## Phase 2 — Locals (Seam V)

7. A template with `<%# locals: (title:) %>` renders with
   `render("x", title: "…")`
8. A missing required local raises `ArgumentError: missing keyword: :title`
9. An undeclared local passed in raises `ArgumentError: unknown keyword:`
10. A default (`badge: nil`) is honored when the local is omitted
11. A template with no declaration raises when passed any local, with the
    template name in the message
12. Line numbers survive the declaration: a `raise` on the template's third
    line reports `views/x.erb:3`

## Phase 3 — Discovery and boot integration (Seams V, B)

13. `Monk.boot(App)` compiles every `*.erb` under the app's `views` root,
    recursively; a nested template is addressable as `"posts/row"`
14. A template with a syntax error fails the boot with
    `Monk::TemplateSyntaxError` naming file and line — never at request time
15. `render` of an unknown name raises `Monk::TemplateNotFoundError` listing
    the root it looked under
16. A template declaring a local named `layout` fails the boot
17. After `Monk.boot(App)`, the views registry is `Ractor.shareable?`
    (Seam B, alongside the existing route assertions)
18. `views "app/views"` overrides the default root; an app with no views
    directory boots exactly as it does today

## Phase 4 — Layouts (Seams V, W)

19. `layout "layouts/app"` wraps a render, with `<%= yield %>` receiving the
    inner HTML unescaped
20. `render "x", layout: false` skips the class-level layout
21. `render "x", layout: "layouts/print"` overrides it
22. A layout receives the page's locals filtered to what it declares; a
    layout declaring nothing receives nothing
23. An ivar set in the route block is readable in both the page and the
    layout (documents the ambient-value path)

## Phase 5 — HTML through the Rack boundary (Seam W)

24. `get("/") { render "index" }` → `200`, body is the rendered HTML,
    `content-type: text/html; charset=utf-8`
25. A route that renders and then calls `json` gets the JSON content-type
    (last writer wins, no interference)
26. An exception raised inside a template is handled by the app's registered
    `error` handler like any other route exception, with the `.erb` file and
    line in the reported backtrace
27. `halt` from inside a route that already rendered returns exactly the
    halt response

## Phase 6 — Static assets (Seam X)

28. A file under `public/` is served with the right `content-type` and body
29. `ETag` is present and stable across requests; `if-none-match` with it
    returns `304` and an empty body
30. `cache-control: public, max-age=0, must-revalidate` by default;
    `?v=<etag>` switches it to `max-age=31536000, immutable`
31. `HEAD` returns the same headers with an empty body
32. An unknown asset path falls through to routing (and to the app's `404`
    handler), not to a bare asset `404`
33. An asset path wins over a splat route registered at the same path
34. Traversal (`/../../etc/passwd`, encoded variants) is not served in
    either mode
35. `asset_path("/css/app.css")` returns the path with the `?v=` stamp in
    production and without it in development
36. Dev mode (`MONK_ENV != "production"`) reflects an edited file on the
    next request with no restart; production serves the boot-time body even
    after the file changes on disk
37. `assets false` disables the whole lookup

## Phase 7 — SCSS (Seam Y)

38. `Monk::Views::Scss.register("styles/app.scss", as: "/css/app.css")`
    plus `Monk.boot(App)` puts compiled CSS in the manifest at that path,
    served with `text/css`
39. An `@use`'d partial (`_vars.scss`) is picked up without being registered
40. A Sass syntax error fails the boot with `Monk::ScssCompileError` naming
    file and line
41. The `dart-sass` subprocess is closed after boot (asserted on the
    compiler object, not by counting processes)
42. Registering SCSS without `sass-embedded` installed raises a clear
    "add sass-embedded to your Gemfile" error, not a `LoadError` from deep
    inside
43. `require "monk"` alone never loads `sass-embedded` (mirrors
    `test/persistence_test.rb`'s opt-in assertion)

## Phase 8 — Real Ractor integration (Seam Z)

44. Several real Ractors rendering the same template concurrently all get
    correct, independent output (locals don't bleed across workers)
45. Several real Ractors reading the manifest concurrently all get correct
    bodies and ETags
46. An app with views, assets and SCSS all configured is `Ractor.shareable?`
    after `Monk.boot`, and `kino --check` agrees (manual, per `PLAN.md` step
    21's precedent)

## Phase 9 — Scaffold, docs, demo

47. `monk new my_app --views` (or views by default — decide at this step
    from how Phase 3's "no views directory" case feels) writes
    `views/layouts/app.erb`, `views/index.erb`, `public/css/app.css` and
    `public/js/app.js`, and the scaffold test asserts the generated app
    boots and renders
48. The generated layout demonstrates `<script type="module">` and an
    import map, since that's the entire JS story (`docs/views.md`, "Vanilla
    JS with no build step")
49. `config.ru` in this repo grows an HTML route alongside the JSON ones, so
    `bin/server` shows a real page
50. README gets a "Views" and a "Static assets" section; `CONTEXT.md` gets
    the three vocabulary entries proposed in `docs/views.md`; `NOTES-V2.md`
    marks the templating candidate done
51. An ADR for the two calls most likely to be questioned later:
    compile-at-boot-only, and escape-by-default

## Explicitly out of scope for this plan

Everything listed under "Explicitly out of scope" in `docs/views.md`, plus:
streaming/chunked bodies (a known v1 limitation tracked in `NOTES-V2.md`),
live reloading of `.rb` files, and the CSRF view helper `docs/auth-sessions.md`
will want — that belongs to `PLAN-AUTH.md`.
