# Live updates — `Monk::Live`

Server-owned state changes, and every open browser tab showing it updates by
itself: the server renders an HTML fragment with the same views it already
has, pushes it over the WebSocket, and a small client morphs it into the page.
No polling, no client-side copy of the data to keep in sync, no JavaScript of
your own. Design rationale is in `docs/history/reactive-partials.md` and ADRs
0007–0011; the phase-by-phase build is `docs/history/plan-live.md`. This page is how to use
it.

```
monk new my_app --live
```

scaffolds a working demo (a counter whose tabs update together); everything
below is what that demo is made of.

## The shape

Two processes, because `Monk::WebSocket` runs as its own process (Kino can't
carry sockets):

```
 HTTP app (bin/server)                      WebSocket process (bin/websocket_server)
 route changes state                        browsers' sockets end here
 Monk::Live.patch(...)  --- Redis --->      Monk::Live::HANDLER relays it, per connection
 renders the partial once                   checks each subscription against your rules
```

Redis (`Monk::WebSocket::RedisFanout`) is what carries an update between the
two, which is why `--live` implies `--redis`.

## Publishing (server side)

```ruby
# config/live.rb, required by both processes
Monk::Live.configure(registry: Monk::WebSocket::RedisFanout.new(Monk::WebSocket::Registry.new, redis_url: ENV.fetch("REDIS_URL")))

# in a route
Monk::Live.patch "contacts:7", to: "#contact-42", partial: "contacts/_row", contact: contact
```

`patch` renders `views/contacts/_row.erb` **once** and pushes the result to
everyone subscribed to the topic `"contacts:7"`. `to:` is a CSS selector
matched with `querySelectorAll`, so one call can update every element that
matches. The same call takes `mode:`:

| Call | Effect on each matched element |
| --- | --- |
| `patch(topic, to:, partial:, **locals)` | morph it into the new HTML (default; keeps focus, typed text, scroll) |
| `patch(..., mode: :replace)` | swap it outright |
| `append` / `prepend` | insert the HTML as its last / first child |
| `remove(topic, to:)` | delete it (renders nothing) |
| `batch(topic) { \|b\| b.patch(...); b.remove(...) }` | several of the above in one message |

`to:`, `partial:` and `mode:` are reserved keywords; every other keyword is a
local for the partial. A partial reads them as `locals[:contact]`, like any
Monk view.

**A live partial must be request-independent.** It is rendered with a detached
context, not a request: no `params`, no session, no per-request helpers.
Everything it shows must arrive as a local. The default layout is never
applied, and passing a `layout:` local raises.

## Page side

```erb
<ul id="contacts" <%= live_topic "contacts:#{current_user.id}" %>>
  <%= render "contacts/_row", ... %>
</ul>
```

`live_topic` renders `data-live-topic="..."` (several topics allowed,
space-separated) and refuses a topic the server would refuse. The layout loads
the client:

```html
<meta name="monk-live-url" content="ws://localhost:9293">
<script type="module" src="/js/monk_live/monk_live.js"></script>
```

The runtime lives in the gem (`Monk::Live.client_dir`; `monk new --live` copies
it to `public/js/monk_live/`, and its files import each other by relative
path, so keep them together). A page with no `data-live-topic` never opens a
socket.

What the client does for you:

- Subscribes to every topic on the page and applies patches as they arrive.
- **Keeps what the user is doing.** A morph leaves the focused input's text
  and selection alone, doesn't close a `<details>` the user opened, and skips
  anything inside `data-live-ignore`.
- **Recovers.** It counts messages per connection, and on a gap, a reconnect,
  or a failed refetch it re-fetches the current page and morphs it in, so the
  page converges without a reload. If that refetch comes back as an error, a
  non-HTML response or any redirect (a login page, say) it stops rather than
  morph something wrong. Reconnects back off from 500ms to 30s.

Everything it does is reported as DOM events on `document`; there is no JS
API: `monk-live:connected`, `disconnected`, `subscribed` (`{topics, denied}`),
`patched` (`{target, mode, matched}`), `gap`, `resynced`, `resync-failed`,
`stopped` (`{reason}`).

Client-only state inside a patched region is reset by a morph unless the
server's HTML carries it or you mark it `data-live-ignore`. Keep local-only
widgets (an open menu, a half-typed draft outside a focused input) outside
patched regions.

## Who may subscribe

Nothing, until a rule says so:

```ruby
module AppLive
  OWN = proc { |subject, topic| topic == "contacts:#{subject}" }
  PUBLIC = proc { |_subject, _topic| true }
end
Monk::Live.authorize("contacts:*", &AppLive::OWN)
Monk::Live.authorize("news", anonymous: true, &AppLive::PUBLIC)
```

- A pattern is an exact topic or a prefix ending in one `*`. **The first
  matching rule decides**, so put specific rules above general ones. A topic
  no rule matches is denied.
- The block gets the verified subject (from `Monk::Auth`, when the WS server
  authenticates) and the topic. A block that raises denies.
- **An anonymous connection is denied unless the rule says `anonymous: true`**,
  and the block isn't called for it. Without this,
  `topic == "contacts:#{subject}"` would let a nil subject subscribe to
  `"contacts:"`.
- The block has to be Ractor-shareable: define it in a module or class body
  (self there is shareable), not inline in a script's top level.
- A client's topic must match `[\w:.\-/@]{1,200}`, and a connection holds at
  most 100 topics (`configure(registry:, max_topics:)`). Denials never say why
  or whether the topic exists.
- Rules run when a client subscribes. **Access is not re-checked while it is
  connected**: someone who loses access keeps receiving that topic until they
  disconnect.

Choosing topics: one per recipient (`contacts:7`, each user subscribes to
their own channel, and you publish once per person to tell) is the default
that fits deny-by-default. One per entity (`contact:42`, everyone watching
that contact subscribes) works too and needs a rule that can answer "may this
subject watch this entity?". A fragment that differs per viewer only works
with recipient topics.

## Running it

- **Both processes must be up, plus Redis.** `bin/server` publishes,
  `bin/websocket_server` (which runs `Monk::Live::HANDLER`) delivers.
- `WS_ALLOWED_ORIGINS` must list the origin your pages are served from, or
  the browser's socket is refused. `LIVE_WS_URL` is what the layout gives the
  client (`wss://` in production).
- The HTTP process must have booted (`Monk.boot`) before publishing, because
  views are frozen there; otherwise `Monk::Live::NotFrozenError` says so.
- **If Redis is down, `Monk::Live.patch` raises** (`Redis::CannotConnectError`),
  after delivering to subscribers in its own process. A route that publishes
  after a successful write would fail with it; wrap the call in your own
  `rescue` if a missed push should not fail the request.
- If delivering to a connection fails unexpectedly, the server closes that
  connection (code 1011), and the client reconnects and re-syncs.

## Cost and limits

Rendering is cheap (about 3µs a fragment); delivery is what scales, roughly
with subscriber count. Measured on an 8-core Mac: about 100ms to fan one
message out to 1,000 connections on a single topic, during which the
single-threaded registry also holds up every other subscribe and
unsubscribe. Per-recipient topics keep those counts small. Not built, on
purpose: client → server events (`onclick` and forms over the socket),
per-viewer diffing, presence, replay of missed messages (a resync re-fetches
the page instead).

Rate limiting or throttling of chatty topics (typing indicators, say) is the
app's job.
