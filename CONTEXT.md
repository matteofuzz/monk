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

**LOG_LEVEL**:
The minimum severity `Monk::Log`'s `.debug`/`.info`/`.warn`/`.error` methods actually write, one of four values — `debug`, `info` (the default when unset), `warn`, `error`, least to most severe. Internally it's just the `:log_level` key inside `Settings`, resolved once at `Boot` into `Monk::Log`'s own threshold rather than read per call. A call below the threshold is a no-op, not buffered or dropped after formatting — cheap enough to leave debug logging in place across environments rather than stripping it. Distinct from `#write`, `Monk::Log`'s unconditional per-request access-log line, which `LOG_LEVEL` never gates.
_Avoid_: verbosity, log verbosity, debug mode

**Live**:
`Monk::Live`: an opt-in layer (`require "monk/live"`) above `Monk::WebSocket` that pushes server-rendered HTML to open browser tabs. Server-owned state stays on the server: a route changes it and calls `Monk::Live.patch`, and a small client morphs the resulting fragment into the page, so there is no client-side copy to keep in sync. Lives beside `Monk::WebSocket` and `Monk::Auth` in `lib/monk/`, and neither of those depends on it.
_Avoid_: LiveView, reactive framework, realtime layer

**Topic**:
An opaque name (`"contacts:7"`) that publishers address and pages subscribe to; it maps onto a `Registry` key. Both per-recipient topics (`contacts:7`) and per-entity ones (`contact:42`) work on the same primitive. Subscribing is denied by default: only a topic matched by a `Monk::Live.authorize` rule is allowed, and an anonymous connection is denied unless the rule says `anonymous: true`.
_Avoid_: Channel, room, stream

**Patch**:
One DOM operation pushed to a page: a CSS selector, a mode (`morph`, `replace`, `append`, `prepend`, `remove`) and HTML. A publish is a patch, or a batch of them, rendered once by the publisher and shared by reference (as a frozen String) with every subscriber.
_Avoid_: Update, diff, delta

**Live partial**:
A `Monk::Views` template rendered for a patch. It runs with a detached `Context`, not a request, so it sees only its `locals` (`locals[:contact]`), never `params`, the session or per-request helpers, and it is never wrapped in the default layout.
_Avoid_: Component, widget

**Resync**:
How the client recovers when it may have missed a patch (a `seq` gap, a reconnect, a failed refetch): it refetches the current page over HTTP and morphs it in, keeping focus and typed text. The page's own view is the only definition of what a region looks like, so patches are an optimization over "the page can always be re-fetched". If the refetch isn't the app page (an error, a non-HTML answer, any redirect) the client stops instead of morphing.
_Avoid_: Snapshot, refresh, replay

**Job**:
A unit of background work: a `Monk::Job` subclass with a `self.perform`, and one enqueued call of it (`SendReceipt.enqueue(42)`), stored as a row in `monk_jobs` plus its payload. Its arguments are plain JSON values, checked when it's enqueued. A job may run more than once (delivery is at-least-once), so it has to be safe to repeat. The class is found again in the job process by its name, only ever among loaded `Monk::Job` subclasses.
_Avoid_: Task, worker (a worker is what runs jobs), message

**Queue**:
A name a job is enqueued under (`queue "mailers"`, `"default"` otherwise), and nothing more: there's no queue object or table of its own, only a column. A job process serves the queues it's given, in order.
_Avoid_: Channel, topic (a Live term), tube

**Job state**:
Where a job is in its life, one of four: `available` (can be claimed now), `scheduled` (not due yet: enqueued with `wait:`/`at:`, or waiting to retry), `running` (claimed by a job process), `failed` (out of attempts, or never worth retrying; kept until retried or discarded). A finished job has no state: it's deleted. Each state has its own partial index, so claiming never looks at scheduled or failed jobs.
_Avoid_: Status, stage

**Payload**:
The part of a job the queue itself never updates: its class name, its JSON arguments, and its last error, in `monk_job_payloads`. Kept apart from the narrow `monk_jobs` row that claiming rewrites, so a claim never rewrites the arguments (ADR 0013).
_Avoid_: Body, data, message

**Job process**:
`bin/jobs`: one OS process running `Monk::Jobs::Runtime`, a supervisor in its main Ractor and a pool of worker Ractors, each running one job at a time on its own database connection. It checks in (`monk_processes`) so that, if it dies, another job process gives its running jobs back to the queue. Never embedded in the web server's process.
_Avoid_: Worker (one worker Ractor inside it), daemon, consumer

**Stager**:
The job process supervisor's once-a-tick step that turns due `scheduled` jobs into `available` ones, in batches. Every job process runs it; `SKIP LOCKED` keeps two from moving the same job. It's why a scheduled job or a retry can start up to one tick late.
_Avoid_: Scheduler (that's recurring jobs, which Monk doesn't have), dispatcher, promoter

