# HTML views, static assets, and (optionally) SCSS

Status: **implemented 2026-09-05** — ERB views (`lib/monk/views.rb`) and
static assets (`lib/monk/assets.rb`), with `test/views_test.rb`,
`test/assets_test.rb` and two cases in `test/ractor_integration_test.rb`.
SCSS is **explored but deliberately not built**: plain CSS only, for now
(see "SCSS" below — the design stands if that changes). Declared locals
are likewise explored and not built (see "Locals"). No ADR yet; the
"compile every template at boot, never at request time" call and the
"auto-escape by default" call are the two most likely to want one.

This doc started as the design pass and now doubles as the record of what
shipped and what was left on the table. Six throwaway spikes preceded it,
plus two Ractor bugs the integration tests caught afterwards that no amount
of design would have — see "What the real Ractor tests caught". Plan:
`PLAN-VIEWS.md`.

**Caveat on the spike results below.** Monk's target Ruby is 4.0.6
(`.ruby-version`), and `PLAN-WEBSOCKET.md` sets the rule that Ractor
behavior is measured on 4.x directly, never inferred from a 3.x result.
The session that produced this doc had only Ruby 3.3.6 available, so every
Ractor-flavored number below is provisional and re-run on 4.0.6 as Phase 0
of `PLAN-VIEWS.md`. The findings split cleanly into two kinds: pure ERB /
asset mechanics (stdlib behavior, version-stable, safe to design against)
and Ractor isolation behavior (must be re-measured). Each finding says
which it is.

## The shape of the feature

Three things, in dependency order:

1. **Views** — `.erb` templates compiled at boot, rendered from a route via
   `render`, with layouts, partials, and HTML-escaping on by default.
   **Built.**
2. **Static assets** — the `.css`, `.js`, images and fonts those templates
   link to, served by Monk itself with `ETag`/`304`, out of a boot-built
   manifest. **Built.**
3. **SCSS** — opt-in, compiled to CSS *at boot* into that same manifest,
   requiring `sass-embedded` in the app's own `Gemfile`. **Not built** —
   the design below holds, and nothing in (1) or (2) depends on it, so it
   stays a one-file addition if plain CSS ever stops being enough. No JS
   preprocessor, ever (see "Vanilla JS with no build step").

(1) and (2) are stdlib-only (`erb`, `cgi/escape`, `digest`) and live in
core. (3), if it ever lands, is opt-in exactly like
`Monk::Persistence::Pg` — a require the app makes, plus a gem the app
declares.

## The one constraint that decides the whole design

Everything is compiled, read, and frozen **at boot, in the main Ractor**.
Not lazily, not per-request, not memoized on first use.

This isn't a performance preference, it's forced. A worker Ractor cannot
build a template cache, because a cache is shared mutable state and the
whole point of Monk is that there isn't any; it cannot mutate a shared
module to install a compiled method (Ruby prohibits touching a
class/module's state from a non-main Ractor, and where a given Ruby version
*doesn't* prohibit it, doing it anyway is a race across true-parallel
workers); and it cannot even call into a library that memoizes an unfrozen
object in a module ivar — the exact failure mode already recorded for
Sequel (`docs/persistence-ractor-connections.md`) and `Rack::Utils`
(`lib/monk/base.rb`'s `parse_query_string` comment). Spike 4 below shows
`sass-embedded` failing the same way, for the same reason.

The lazy-compile-and-cache design every other Ruby template engine uses
(Tilt, ActionView, Sinatra) is therefore unavailable here. What's left is
better anyway, and it's the shape `Boot` already has: **`Monk.boot(App)`
compiles every template, builds the asset manifest, compiles any registered
SCSS, and freezes all three into `Ractor.shareable?` structures.** A
template with a syntax error fails the boot, naming the file and line —
same fail-fast posture as ADR 0003's route-shareability check, for the same
reason.

## Spike results

Six spikes, 2026-09-05, Ruby 3.3.6, stdlib `erb` 4.0.3 +
`sass-embedded` 1.104.0.

### Spike 1 — compile-to-method, auto-escaping, layouts, Ractor render

*Mechanics (version-stable), except the Ractor render itself.*

Each template compiles once into a real instance method on a module that
`Monk::Context` includes:

```ruby
compiler = ERB::Compiler.new("-")
compiler.pre_cmd    = ["_erbout = +''"]
compiler.post_cmd   = ["Monk::Views::Raw.new(_erbout)"]
compiler.put_cmd    = "_erbout.<<"
compiler.insert_cmd = "_erbout.<< Monk::Views.h"
src, = compiler.compile(source)
module_eval("def #{method_name}(...); #{src}; end", template_path, 0)
```

Four things fall out of that, all verified:

- **Auto-escaping with the stdlib, no Erubi.** `ERB::Compiler` emits
  `insert_cmd((expr).to_s)` for every `<%= %>`; pointing `insert_cmd` at
  `Monk::Views.h` makes escaping the default rather than something the
  template author has to remember. Stock ERB's `<%= %>` is raw, so this is
  a deliberate deviation from ERB semantics and has to be documented
  loudly — it is also the only defensible default for a framework that
  renders user data.
- **`raw` survives `.to_s`.** The `.to_s` in that generated call is
  hardcoded by `ERB::Compiler`, and `String#to_s` downgrades a subclass
  instance to a plain `String` — which would silently strip an
  "already-safe" marker. Defining `Raw#to_s` to return `self` is the whole
  fix; `h` passes a `Raw` through untouched and escapes everything else.
- **Layouts need no machinery at all.** The compiled template is a method,
  so `<%= yield %>` in a layout is just Ruby's `yield`: render the inner
  template first, then call the layout method with a block returning it.
  Because `render` returns a `Raw`, the inner HTML isn't double-escaped on
  the way through.
- **Rendering from a worker Ractor works** (3.3.6 — re-verify on 4.0.6).
  Modules and classes are always shareable; the per-request `Context` that
  actually runs the method is created inside the worker and never crosses a
  boundary, so it stays exempt exactly like it already is for routes
  (`docs/ractor.md`, "Why `Context` is exempt").

Cost: **50,000 renders of a small template in 129ms (~2.6µs each)**, which
is the point of compiling to a method rather than `eval`ing per request.

### Spike 2 — locals and error quality

*Mechanics (version-stable).*

Boot-time compilation means a template's local variables must be known at
compile time — there is no request-time binding to inject them into. Three
options were measured; details and the recommendation are in "Locals"
below. The error quality of the recommended one (a declared signature) is
the reason it wins:

```
missing local        -> ArgumentError: missing keyword: :title
unknown local        -> ArgumentError: unknown keyword: :nope
typo inside template -> NameError: undefined local variable or method `nmae'
                        @ views/typo.erb:1
runtime raise        -> RuntimeError @ views/boom.erb:2
syntax error at boot -> SyntaxError: views/bad.erb:3: unexpected end-of-input,
                        expecting `end'
```

Backtraces point at the `.erb` file and the right line, because
`module_eval` takes the template path and line 0 and ERB's generated source
preserves line breaks. One gotcha found and fixed in the spike: stripping
the `locals:` declaration line shifts every subsequent line number by one —
blank the line, don't remove it.

### Spike 3 — the static asset manifest

*Mechanics, plus one Ractor read (re-verify on 4.0.6).*

At boot, walk `public/`, and for each file record body, content-type (from
a small extension map), and an `ETag` (16 hex chars of SHA-256 over the
body). `Ractor.make_shareable` on the resulting nested hash succeeds, and a
worker Ractor reads entries out of it fine. Two consequences worth naming:

- **Path traversal is structurally impossible in production.** Lookup is an
  exact-match hash fetch of a path that was enumerated at boot;
  `/../../etc/passwd` simply isn't a key. No sanitizing code to get wrong.
- **Dev mode can read from disk inside a worker Ractor** — verified — so
  the edit-refresh loop for CSS/JS doesn't need a restart. That's a
  per-request `File.binread`, no cache, dev only.

### Spike 4 — `sass-embedded`: boot-only, and that's fine

*Ractor isolation behavior (re-verify on 4.0.6, though the mechanism is
version-independent).*

```
require "sass-embedded"            150ms
first  compile                      10ms
next 3 compiles                    4ms total (~1.3ms each)
Sass.compile_string in a Ractor    Ractor::IsolationError: can not get
                                   unshareable values from instance
                                   variables of classes/modules from
                                   non-main Ractors
```

Third gem to fail this way (Sequel, `Rack::Utils`, now `sass-embedded`),
and the reason is structural — `Sass.compile` memoizes a lazily-created
`Sass::Compiler` in a module ivar, and that compiler owns a live pipe to a
`dart-sass` subprocess, which is not a shareable thing under any
arrangement.

This isn't an obstacle to the design; it *is* the design. SCSS compiles at
boot in the main Ractor, the resulting CSS string goes into the same frozen
asset manifest as a hand-written `.css` file, and no worker ever touches
Sass. 10ms once at boot for the first stylesheet is a non-issue.

### Spike 5 — the dev-mode reload path

*Mechanics, plus one Ractor result to distrust.*

For CSS/JS, dev reload is just re-reading the file (spike 3). For `.erb` it
can't be: a worker Ractor must not install a recompiled method on the
shared views module. The workable dev path is to `eval` the compiled ERB
source into a lambda per request and `instance_exec` it on the `Context` —
no shared state touched, semantics identical to the compiled path (same
generated source, same escaping, same locals as keyword args), and it costs
**~18µs per render** (500 evals in 9ms), which is irrelevant in
development.

**One 3.3.6 result to explicitly distrust:** a worker Ractor was *able* to
`module_eval("def ...")` on a shared module without raising. Whether 4.0.6
still permits that is unknown and doesn't matter — Monk shouldn't do it
either way. Two workers recompiling the same module in parallel is exactly
the "silently stops being safe" failure ADR 0003 exists to prevent. Noted
here so a future reader doesn't rediscover it and think it's a shortcut.

### Spike 6 — the dart-sass subprocess doesn't have to outlive boot

*Mechanics.*

`Sass.compile` leaves its subprocess running for the process lifetime. An
explicit `Sass::Compiler.new` … `#close` compiles identically and reaps the
subprocess (verified by process count). Monk's SCSS step therefore opens
one compiler, compiles everything registered, and closes it — a Monk app
serving traffic has no `dart-sass` process attached to it.

## The API, as built

```ruby
require "monk"

class App < Monk::Base
  views   "views"           # default; relative to Dir.pwd, resolved at boot
  assets  "public"          # default; `assets false` disables asset serving
  layout  "layouts/app"     # optional default layout for every render

  get("/") { @title = "Home"; render "index", posts: Post.where(published: true) }

  # a fragment, no layout
  get("/posts/:id/row") { render "posts/row", post: Post.find(params[:id]) }
end

run Monk.boot(App)
```

`views/layouts/app.erb`:

```erb
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

`views/index.erb`:

```erb
<h1><%= @title %></h1>
<ul>
  <% locals[:posts].each do |post| -%>
    <%= render "posts/row", post: post -%>
  <% end -%>
</ul>
```

### What `render` is

`render(name, **locals)` → a `Raw` string, and as a side effect sets
`content-type: text/html; charset=utf-8` on the response unless something
already set it.

It **returns** rather than throwing, unlike `Context#json` and
`Context#halt` — that's what makes partials work: a template rendering
another template is the same call. The route block's return value is
already the response body, so `get("/") { render "index" }` needs nothing
extra.

Reserved keyword: `layout:` (`false`, or a template name overriding the
class-level default). With locals passed as a hash rather than declared
(see below), there's no collision to design around — `layout` is simply not
a key `render` forwards.

The default layout wraps the **outermost** render of a request only, so a
partial rendered from inside a template isn't wrapped again. That's one
boolean on the `Context` (`#rendering`), not a render stack.

Helpers added to `Monk::Context`: `render`, `h`, `raw`, `asset_path`.
That's the whole surface. No tag builders, no `link_to`, no form helpers —
the templates are HTML.

### Locals — decided: no declaration syntax

**What shipped is option 1 below, plus ivars, and nothing else.**
A `locals` hash passed to `render` and read as `locals[:post]`, and ivars
set in the route (`@title`), which templates and layouts see because they
run with `self` bound to the same `Context`. The declared-signature form (option 3 in the original
exploration, kept below because the analysis stands) was explored, spiked,
and deliberately not built — it's real machinery for an error message, and
Monk's stance everywhere else is that plain hashes beat a layer.

What that costs, stated plainly: a local you forgot to pass reads as `nil`
rather than raising `missing keyword: :title`, and a typo'd key is silent.
The spike below is what a future change of mind would start from.

Three options were on the table; the constraint that kills the familiar
ones is that names must exist at compile time.

1. **`locals[:title]`** — a plain hash argument, zero machinery, and
   consistent with `Monk::Persistence`'s "plain Symbol-keyed hashes, not
   objects" stance. **Chosen**, for exactly that consistency; the
   ergonomic cost is real but is paid mostly by partials, which is where a
   hash is the right shape anyway.
2. **`method_missing` on `Context`** resolving names against a locals hash
   — nicest to type, but it's runtime magic that makes every genuine
   `NoMethodError` in a template ambiguous. Rejected.
3. **A declared signature (explored, not built)** — `<%# locals: (title:, badge: nil) %>`
   as the template's first line, compiled straight into the method's
   keyword parameters. Same syntax Rails 7.1 uses for strict locals, so
   it's not a Monk invention. Templates read as plain Ruby locals
   (`<%= title %>`), defaults are ordinary Ruby defaults, and the errors in
   spike 2 come free from Ruby's own argument checking — no validation code
   in Monk at all. A template with no declaration accepts no locals.

With no declarations, the layout question answers itself: the layout is
rendered with the same `locals` hash as the page, and reads whatever keys
it cares about. No filtering rule, no `ArgumentError` to design around.

Ambient values that aren't really "arguments" have the second,
no-machinery route: a route block and its templates and the layout all
execute with `self` bound to the *same* `Context`, so `@title = …` set in
the route is readable in both. In practice this is the primary idiom and
`locals` is for partials — which is roughly the opposite of what the
original design assumed, and is why the declared-signature machinery
would have earned less than it looked like it would.

## Static assets

`public/` is walked at boot into a frozen manifest keyed by URL path.
Lookup happens in `Base.dispatch` **before** route matching, for `GET` and
`HEAD` only. Assets-before-routes is the conventional order (it's what
`Rack::Static` in front of an app does) and it means a catch-all splat
route can't accidentally shadow a stylesheet; the tradeoff — a route can't
override a path that exists as a file — is worth naming in the README.

Per-response behavior: `content-type` from the extension map (text types
get `; charset=utf-8`), `etag`, `cache-control: public, max-age=0,
must-revalidate`, and a `304` when `if-none-match` matches — the header is
split on commas, so a browser sending several candidates is handled.
`HEAD` returns those headers plus `content-length` and an empty body.
`asset_path("/css/app.css")` appends `?v=<digest>`; a request carrying a
matching `v=` gets `cache-control: public, max-age=31536000, immutable`
instead. That's the whole caching story — no digested filenames, no
manifest.json, no build step.

In development (`MONK_ENV != "production"`) the manifest is bypassed
entirely and the file is read from disk per request, with an ETag computed
from what was just read and `cache-control: no-cache` — so editing CSS or
JS needs a refresh, not a restart, and a browser can't serve you a stale
copy of the file you just changed. `asset_path` doesn't stamp in
development for the same reason. Dev is also the only mode that has to
sanitize the request path, since it hits the filesystem: the path must
resolve back inside the assets root. `PATH_INFO` is deliberately not
un-escaped there — an encoded `%2e%2e` stays a literal, nonexistent
filename, and a decoded `..` is caught by the containment check.

Which mode is in play is decided **once, at boot** (`MONK_ENV` read in
`freeze_registry!`), never per request: `ENV` is main-Ractor state, and a
worker reading it is the next isolation error waiting to happen.

Production deployments that put nginx or a CDN in front of Monk should keep
doing that; this exists so that a Monk app is complete on its own, not to
compete with a CDN.

## Vanilla JS with no build step

There is no JS pipeline and there will not be one: no bundler, no
transpiler, no npm dependency, no `node_modules` anywhere near a Monk app.
`public/js/*.js` is served as-is. What makes that a real option rather than
a limitation, and what the scaffold should demonstrate:

- **ES modules natively.** `<script type="module" src="/js/app.js">`, and
  `import { x } from "./x.js"` between your own files, works in every
  browser Monk could care about. Relative paths with real extensions, no
  resolution step.
- **Import maps for anything third-party.** A `<script type="importmap">`
  block in the layout maps a bare specifier to a URL (vendored under
  `public/js/vendor/` or a CDN), which is the no-build answer to the one
  thing plain ES modules can't do alone.
- **Per-page scripts** are just another `<script type="module">` the page
  template emits.

The unavoidable losses are worth stating plainly: no tree-shaking, no
minification, no fingerprinted bundle, no TypeScript, and JSX or SFC-style
component files are out of reach entirely. An app that needs those should
run its own build and drop the output into `public/` — Monk will serve it
without knowing or caring.

## SCSS — designed, not built

**Decision: plain CSS only, for now.** The bar for including SCSS at all
was "only if we find a very clean simple pattern"; the pattern below
clears it, and was still declined — nothing in the demo or the scaffold
needs more than native CSS nesting and custom properties, and the honest
cost (a restart to see a stylesheet change, where a `.css` edit needs a
refresh) is a real regression for the one workflow this whole feature
exists to make pleasant.

The design is recorded in full because it stays a one-file addition — no
request-path code changes, no core changes — if that ever stops being
true. This is the pattern it would take:

```ruby
require "monk/views/scss"
Monk::Views::Scss.register("styles/app.scss", as: "/css/app.css")
```

One explicit line per compiled stylesheet, before `Monk.boot(App)`,
mirroring `Monk::Persistence::Pg.register`. `@use`'d partials (`_vars.scss`)
are pulled in by Sass and never registered. At boot: one
`Sass::Compiler`, compile each registration, insert the CSS into the asset
manifest under its `as:` path, close the compiler.

What makes it clean rather than a pipeline:

- **It adds no request-path code at all.** After boot, a compiled
  stylesheet is indistinguishable from a hand-written `.css` file — same
  manifest, same ETag, same `asset_path`. Deleting the SCSS feature would
  not change a single line of the serving code.
- **The Ractor constraint removes the hard question.** There's no cache
  invalidation design to get wrong, because runtime compilation isn't
  possible in the first place (spike 4).
- **No runtime dependency.** `sass-embedded` goes in the app's `Gemfile`,
  the require is opt-in, and no `dart-sass` process outlives boot
  (spike 6).
- **No conventions to memorize.** No glob, no `_partial` rule enforced by
  Monk, no output-directory mapping — an explicit source and an explicit
  URL.

The cost, and the reason it wasn't built: **editing a `.scss` file would
require a restart**, where editing a `.css` file doesn't. Compilation can't move to the request
path in dev without giving a worker Ractor a Sass compiler, which spike 4
says is impossible. A `bin/assets --watch` script would fix it and is
deliberately not proposed — it's a build tool, which is the thing this
whole section is trying not to become. If restarts prove annoying in
practice, the honest fix is to write plain CSS (nesting and custom
properties are native now), which is why SCSS is opt-in.

## What the real Ractor tests caught

Two bugs, both found by `test/ractor_integration_test.rb` on the first run
and neither visible from any main-Ractor test, review, or spike. Recorded
because they're the argument for that test file existing at all — a
feature can be entirely correct in the main Ractor and entirely broken in
the one that actually serves requests.

1. **`ERB::Util.html_escape` is not Ractor-safe.** Escaping *every*
   `<%= %>` through it meant every render in a worker raised
   `Ractor::UnsafeError` ("ractor unsafe method called from not main
   ractor") — i.e. HTML rendering was broken in exactly the mode Monk
   exists for, while passing 24 green tests in the main Ractor.
   `CGI.escapeHTML` produces byte-identical output and is safe; that's
   what `lib/monk/views.rb` uses, and the reason is a comment in the code
   rather than folklore. Now also recorded as a general finding in
   `docs/ractor.md`.
2. **An unfrozen root path in a module ivar breaks a worker before it
   reads anything else.** `Monk::Assets.root` (and `Monk::Views.root`) are
   read on the request path; left as ordinary unfrozen Strings they raised
   `Ractor::IsolationError` on the *first* call, ahead of the frozen
   manifest they were guarding. Both are frozen in `freeze_registry!`
   now — the same lesson `Monk::Persistence::Registry#freeze_registry!`
   already carried, re-learned on a different ivar.

A third, smaller one was avoided by construction rather than found: every
reader on these modules is a plain `attr_reader` over an eagerly
initialized ivar, never `@x ||= …`, because a lazy reader *writes* on
first access and writing a module ivar from a worker is an isolation
error.

## Ractor-safety notes specific to this feature

- **The views module is a `Module`, so it's shareable by construction**;
  what has to be proven is that its compiled methods only touch shareable
  things. They touch the per-request `Context` (exempt), their own locals,
  and the frozen registry.
- **`Base.call` lazily boots when routes aren't yet shareable.** With views
  in play, a first request arriving in a worker Ractor would try to compile
  templates there — and compiling installs a method on a shared module,
  which is precisely what a worker must not do. `Monk.boot(App)` in
  `config.ru` is already the sanctioned path (README, "Boot and
  Ractor-shareability"); views make it load-bearing rather than merely
  recommended. Still open: whether that lazy path should raise a named
  `Monk::NotBootedError` instead of whatever Ruby produces.
- **The asset manifest holds binary strings.** `Ractor.make_shareable`
  deep-freezes them; nothing on the request path may mutate a body (`+`
  before any `<<`).
- **`ERB::Compiler` runs only at boot**, so ERB's own thread-unsafety and
  ivar memoization are out of scope by construction — the same argument
  that would have made the SCSS story work. What is *not* out of scope by
  construction is anything ERB does at render time: see the
  `ERB::Util.html_escape` bug above.

## Vocabulary

`CONTEXT.md` now carries the three terms this feature introduced — **View**,
**Layout**, **Asset manifest** — in its usual format.

## What Monk owns vs. what stays a plain dependency

Monk owns: template discovery and compilation, the escaping default, the
render/layout/partial protocol, and the asset manifest and its HTTP
semantics. Monk does not own: ERB's syntax (stdlib), Sass (not built at
all), or anything about JavaScript beyond serving bytes.

## Settled during implementation

- **Discovery is recursive over `*.erb`** under the views root, so every
  template is syntax-checked at boot whether or not anything renders it.
  The cost is real and accepted: a stray `index.erb~` editor backup isn't
  matched (the glob wants `.erb` exactly), but a genuinely broken template
  nobody renders still fails the boot.
- **Layouts take the page's whole `locals` hash**, unfiltered — the
  filtered-locals rule only existed to serve declared signatures, which
  weren't built.
- **`HEAD` is synthesized** from the entry: same headers plus
  `content-length`, empty body.

## Open questions

- **Should the lazy boot in `Base.call` raise a named error?** See the
  Ractor-safety note above.
- **`views`/`layout`/`assets` set process-global state, not per-app-class
  state.** Two `Monk::Base` subclasses in one process share one views root
  and one asset root — invisible for the one-app-per-process case every
  Monk app is today, wrong the moment someone mounts two. Fixing it means
  either per-class registries (and a Context that knows its app) or saying
  out loud that Monk is one app per process. Worth deciding before
  something depends on the current behavior.
- **Should `render` also be callable outside a request** (e.g. to render an
  email body from a job)? It only needs a `Context`, so it's nearly free,
  but "a `Context` with no `env`" is a concept the framework doesn't have
  yet.
- **Streaming responses** stay out (`NOTES-V2.md` lists the single-string
  body as a known v1 limitation) — but a `render` that builds one big
  string is the thing a future streaming body would have to unwind. Worth
  knowing before, not solving now.

## Explicitly out of scope (for this doc)

Template engines other than ERB (Haml, Slim, Markdown); JS bundling,
transpiling, or minification; CSS minification/autoprefixing; digested
filenames and a build manifest; asset serving from S3/CDN; HTTP caching
beyond ETag + max-age; partial-layout nesting more than one level;
`content_for`-style named slots; i18n; form/CSRF helpers (`docs/auth-sessions.md`
owns CSRF, and its double-submit design will want one small view helper —
that helper belongs to auth's plan, not this one); live code reloading of
`.rb` files.

## What shipped

ERB views and static assets, core and stdlib-only (`erb`, `cgi/escape`,
`digest`), both compiled/enumerated at `Boot` and frozen. Auto-escaping by
default. Locals as a plain hash, with ivars as the primary idiom for
ambient page data — no declaration syntax. Layouts via Ruby's `yield`,
applied to the outermost render only. Assets before routes, `ETag`/`304`,
a `?v=` digest stamp and `immutable` caching in production, disk re-reads
in development.

No SCSS and no JavaScript tooling of any kind. `monk new` generates a
working HTML page — layout, index template, stylesheet, ES-module entry
point — and this repo's own `config.ru` serves one at `/`, complete with
an import map, so `bin/server` shows a real page rather than a JSON blob.

Left on the table, in descending order of likelihood: SCSS (designed
above, one file), a named error for an unbooted app, and `content_for`-style
named slots (deliberately deferred until something misses them).
