# Monk

A minimalistic, Sinatra-style Ruby web framework designed to be fully `Ractor`-safe: every app it produces is a valid Rack 3 app that is also `Ractor.shareable?`, so it can be served in parallel across Ractor worker pools (e.g. by the Kino server) without silently losing that safety property. Named after Thelonious Monk.

## Language

**StateRactor**:
A user-instantiated, general-purpose primitive (`Monk::StateRactor.new(initial_value)`) that wraps a piece of mutable state inside its own dedicated Ractor. Route code reads it via `#value` and mutates it atomically via `#update { |current| new_value }`, both synchronous calls implemented as request/reply messaging (`Ractor::Port`) under the hood, serialized for free since the owning Ractor processes one message at a time. It is Monk's only sanctioned way to hold cross-request mutable state, because a `Ractor` instance itself is always `Ractor.shareable?` regardless of the mutable state it encapsulates internally — a `StateRactor` instance is frozen at construction and is therefore always shareable too. An `#update` block must be built where `self` is shareable (a Class, as at app-definition time) rather than written inline inside a route handler (where `self` is `Context`, deliberately not shareable) — `Ractor.make_shareable` always requires a Proc's lexical `self` to be shareable, regardless of what the block body touches, so the block should be predefined once and referenced from route handlers rather than written at the call site.
_Avoid_: Shared state, actor, state actor, global state

**Context**:
The per-request object created fresh inside a worker Ractor for each incoming request, exposing helpers like `params`, `halt`, and `json`. A route block accesses it either implicitly — `instance_exec`'d with `self` bound to the Context, for the common case (`get("/x") { params }`) — or explicitly as a block argument, for cases that need to override or customize the Context class (`get("/x") { |ctx| ctx.params }`). Which style applies is decided by the route block's arity. A Context is never shared across Ractors and is therefore exempt from the app's shareability constraints.
_Avoid_: Request object, env, scope

**Boot**:
The lifecycle step, triggered by calling `.freeze!`, that seals an app's route table, Context class, and helpers into a `Ractor.shareable?` structure. It is the one explicit primitive for this transition — callable directly (e.g. in a test asserting the app boots successfully) or triggered automatically by Monk's own Rack entrypoint helper, so ordinary usage never calls it by hand. It works uniformly whether the app is served in classic style (`run App`, routes live on the class) or modular style (`run App.new`, routes live on an instance).
_Avoid_: Freeze, initialize, setup

**View**:
A `.erb` template compiled at `Boot`, in the main Ractor, into an ordinary instance method on a shareable module that `Context` includes — so rendering is a plain method call inside the worker that serves the request, `self` inside a template is that request's `Context` (bare `params`, `render`, and ivars set by the route all resolve), and a template's syntax error fails the boot naming file and line rather than surfacing on a live request. Never compiled at request time: a worker Ractor can hold no template cache and must not install methods on a shared module, which rules out the lazy-compile-and-cache design every other Ruby template engine uses. `<%= %>` HTML-escapes by default (a deliberate break from stock ERB); `raw(...)` opts out. Data reaches a View two ways, both without machinery: ivars set in the route, and the `locals` hash passed to `render`.
_Avoid_: Template object, partial, view object, ERB file

**Layout**:
A View rendered around another View's output, receiving it through Ruby's own `yield` — a consequence of Views being real methods rather than a feature built for the purpose. Applied to the outermost `render` of a request only, so a partial rendered from inside a template isn't wrapped again.
_Avoid_: Wrapper, master page, shell

**Asset manifest**:
The frozen map from URL path to body, content-type and ETag, built by walking the assets root once at `Boot` and sealed with the route table. Every static response in production is served from it, which makes path traversal structurally impossible rather than defended against — a path that wasn't enumerated at boot simply isn't a key. Development bypasses it and reads the file per request instead, so an edited stylesheet needs a refresh rather than a restart.
_Avoid_: Asset pipeline, static middleware, cache

**Settings**:
A boot-frozen facility for app-defined configuration values. An app declares its keys once via `Monk::Settings.configure { required :key; optional :key, default: ... }`; required keys missing at `Boot` raise, the same fail-fast posture `Boot` already takes elsewhere. Values are read back either as `Monk::Settings[:key]` or, per-request, as `Context#settings` — and reading a key nobody declared raises rather than returning `nil`. Keys are flat (no namespacing) and values are always Strings — no type coercion. Deliberately separate from `Persistence.register` and `Auth.configure`, which keep their own bespoke per-feature config; `Settings` is for `MONK_ENV` and everything else an app needs to configure.
_Avoid_: Config, configuration, options

**MONK_ENV**:
The tier an app is running under: one of four values — `development` (the default when unset), `test`, `staging`, `production` — read via `Monk.env` and its predicates (`.development?`, `.test?`, `.staging?`, `.production?`). Internally it's just the `:monk_env` key inside `Settings`, given its own reader because it's checked on nearly every request. `development` is the only tier with verbose request logging and disk-read (rather than manifest) asset serving; `test`, `staging`, and `production` all behave alike for those two checks.
_Avoid_: RACK_ENV, environment, mode
