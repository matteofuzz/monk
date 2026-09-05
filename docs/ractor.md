# Ractors in Ruby 4, and how Monk uses them

This is an explainer of Ruby's `Ractor` model as used inside Monk (see `docs/adr/` for
the design decisions that led here; this doc covers the mechanics and why the code
looks the way it does).

## The model, in brief

A `Ractor` is Ruby's actor-based unit of true parallelism (no shared GVL across
Ractors, unlike Threads). The one rule that makes it safe is the
**shareable/unshareable object split**:

- **Shareable** objects can cross Ractor boundaries by reference: `Symbol`s,
  `true`/`false`/`nil`, numerics, frozen strings, `Class`/`Module` (always shareable,
  regardless of what mutable stuff they hold — e.g. class variables), and any object
  you've explicitly deep-frozen with `Ractor.make_shareable`. A `Ractor` instance
  itself is *also* always shareable, no matter what's happening inside it — this is
  the loophole the whole `StateRactor` design hinges on.
- **Unshareable** objects (ordinary mutable objects, open `IO`, unfrozen closures
  over mutable `self`) can't be passed by reference between Ractors. They get
  deep-copied on send, or you get an error if they can't be copied/frozen at all.
- A `Proc` is only shareable if it's frozen **and** its lexically captured `self`
  and any closed-over locals are shareable. This trips people up constantly, and
  it's exactly what `test/state_ractor_test.rb` documents in its comment.
- **The same rule reaches into `define_method`.** A method created via
  `define_method(:name) { ... }` with an ordinary (unfrozen) block is only
  callable from the Ractor that defined it — calling it from any other Ractor,
  even a worker calling a method a gem defined in main at load time, raises
  `RuntimeError: defined with an un-shareable Proc in a different Ractor`.
  Verified empirically 2026-09-01 (`docs/websocket.md`'s spike): this holds
  even after the method is fully exercised in main first, so it isn't a
  load-order/warm-up problem the way the `Model`/`Persistence` ivar bugs
  were — every call from a non-defining Ractor fails, permanently. The fix
  is the same shareability rule, just applied to the block before it's
  handed to `define_method`: `block = proc { ... }; Ractor.make_shareable
  (block); define_method(:name, &block)` makes the resulting method callable
  from any Ractor. This is a real hazard for any gem (not Monk-specific)
  that uses the common `define_method`-with-a-block idiom for delegators or
  wrapper methods — it silently only works under `:threaded` mode, never
  `:ractor` mode, regardless of whether the gem is otherwise pure Ruby with
  no C extension.
- **A module ivar holding an unshareable object is the other recurring gem
  hazard.** `can not get unshareable values from instance variables of
  classes/modules from non-main Ractors` is what a worker gets from any
  library that lazily memoizes a connection, parser, or compiler into an
  `@ivar` on a module or class. Three found so far, all for structurally
  different objects: Sequel's connection handling
  (`docs/persistence-ractor-connections.md`), `Rack::Utils`' default query
  parser (`lib/monk/base.rb`, `parse_query_string`), and `sass-embedded`'s
  lazily-created `Sass::Compiler`, which owns a pipe to a subprocess
  (`docs/views.md`, spike 4). The fix is never to patch the gem: do that
  work once in the main Ractor at boot and hand workers nothing but the
  frozen result.
- **A stdlib method can be Ractor-unsafe too, and nothing about it says
  so.** `ERB::Util.html_escape` raises `Ractor::UnsafeError` ("ractor
  unsafe method called from not main ractor") when a worker calls it,
  while `CGI.escapeHTML` — byte-identical output, same C extension family
  — is fine. `lib/monk/views.rb` escapes with the latter purely for that
  reason. The difference is invisible in the signature, the docs, and a
  main-Ractor test; only a real worker calling it shows it up, which is
  what `test/ractor_integration_test.rb` is for. Measured on 3.3.6, not
  yet on 4.0.6 — worth re-checking, though the downside is bounded: if a
  newer `erb` has fixed it, Monk's `CGI.escapeHTML` becomes unnecessary
  rather than wrong.
- **`.freeze` on a collection constant is not enough, and the failure is
  deferred to whoever reads it from a worker.** `Hash#freeze` and
  `Array#freeze` freeze the container, not the Strings inside it, so
  `{ ".css" => "text/css" }.freeze` is still unshareable and a worker
  touching that constant gets `Ractor::IsolationError: can not access
  non-shareable objects in constant …`. `Ractor.make_shareable` deep-freezes
  and is what a constant read on the request path needs — `%w[...]​.freeze`
  has the same hole, while a frozen Array of Symbols is fine because
  Symbols are already shareable. Hit for real in `lib/monk/assets.rb`'s
  content-type tables (`docs/views.md`, "What the real Ractor tests
  caught"); `Monk::Scaffold`'s constants have the same shape and are
  harmless only because the `monk new` CLI never leaves the main Ractor.

Ruby 4 (this repo targets 4.0+, see `.ruby-version`) is where Ractor's communication
primitives finally stabilized: the old `Ractor.yield`/`Ractor.take` main-Ractor-centric
handshake is superseded by **`Ractor::Port`** — a shareable, passable object
representing a mailbox endpoint that any Ractor holding a reference to it can
`send`/`receive` on. That's what makes a clean request/reply ("ask") pattern possible
without funneling everything through the main Ractor.

## How Monk uses it

Monk's whole premise (see `README.md`, `docs/adr/0001-kino-agnostic-ractor-design.md`)
is: every app it produces must satisfy `Ractor.shareable?`, so a Ractor-aware server
(Kino) can hand requests to worker Ractors and run them in true parallel, not just
interleaved threads.

### Route freezing — `lib/monk/base.rb`

`Base.freeze!` calls `Ractor.make_shareable` on each route's block individually (not
on the whole array at once), so a failure names *which* route/error-handler is the
offender via `UnshareableRouteError`. Only after every block passes does it freeze
the `routes` and `error_handlers` arrays themselves. `Monk.boot(app)` (`lib/monk.rb`)
just calls this eagerly at server startup —
`docs/adr/0003-boot-time-fail-fast-shareability.md` explains why: Kino silently
degrades to threaded mode for non-shareable apps instead of erroring, so Monk
deliberately fails loud and precise at boot instead of relying on that.

Because `App` is a `Class` (always shareable) and its routes/blocks are now
frozen-shareable too, `test/ractor_integration_test.rb` proves the payoff directly:
it spins up 10 real `Ractor.new(app, id) { |a, id| a.call(env) }` workers, each
independently calling into the exact same frozen route table in true parallel, and
gets back correct, independent responses.

### Why `Context` is exempt — `lib/monk/context.rb`

`Context` holds `@params`/`@status`, is created fresh per request, and is never
itself sent across a Ractor boundary — only the *result* of the route block matters,
and that's copied out at the point the response tuple is returned. So Monk
deliberately never tries to freeze `Context`; it's excluded from the shareability
contract by construction, not by exception-handling.

### `StateRactor` — `lib/monk/state_ractor.rb`, the actual clever bit

Ractors can't share mutable objects, so how do you get a request counter or cache
visible to every worker? `docs/adr/0002-stateless-routes-stateractor.md`'s answer:
don't try to share the *value* — hide it inside a dedicated background `Ractor`,
since the `Ractor` object wrapping it is unconditionally shareable regardless of
what mutates inside its loop:

```ruby
@ractor = Ractor.new(initial_value) do |value|
  loop do
    op, arg, reply_port = Ractor.receive
    case op
    when :value  then reply_port.send(value)
    when :update then value = arg.call(value); reply_port.send(value)
    end
  end
end
freeze
```

Every `#value`/`#update` call is a synchronous "ask": the caller mints a fresh
`Ractor::Port`, sends `[op, arg, reply_port]` into the background Ractor's mailbox,
then blocks on `reply_port.receive` to get the answer. Because the background loop
only ever does one `Ractor.receive` → handle → loop cycle at a time, every `:update`
across every caller Ractor is strictly serialized — that's what gives atomic,
lost-update-free increments, which `ractor_integration_test.rb`'s hammer test proves
directly (8 Ractors × 25 increments each → exactly 200, no races). Freezing the
`StateRactor` instance itself at the end of `initialize` is what makes *it*
`Ractor.shareable?`, so route closures can safely hold a reference to it.

The catch, enforced in `#update`: the block you pass has to already be
`Ractor.make_shareable`-able before it's sent to the worker, which per the Proc rule
above means it must be defined somewhere `self` is already shareable — at
class-body scope (`self` = the app class), not inline inside a route handler
(`self` = `Context`, deliberately unshareable). That's why `config.ru` predefines
`increment = Ractor.make_shareable(proc { |v| v + 1 })` once at app-definition time
and just references it from routes, and why `#update` raises a precise
`UnshareableBlockError` (naming the fix) rather than letting Ruby's generic
`ArgumentError` leak out.

### Known sharp edges

From `NOTES-V2.md`'s known-limitations list: a `StateRactor` runs for the process's
whole lifetime with no shutdown path, a slow `#update` block serializes and blocks
*every* other caller waiting on that same instance (no timeout, no async variant),
and there's no cross-`StateRactor` transactionality if an operation needs to touch
two of them atomically together.
