# Presence — `Monk::Presence`

Whether a signed-in person has a page of your app open, and whether they're
looking at it: **online** (a page open and visible), **away** (only hidden
pages: another tab, another app, a locked phone) or **offline** (none),
with when an offline person was last seen. Counted from the sockets
`bin/websocket_server` holds, read from any process, and reacted to in
`bin/server`. Why it's built this way: ADR 0019.

```
monk add presence
```

adds it on top of `auth` and `websocket` (it counts only signed-in sockets,
so both are needed), and writes:

- `config/presence.rb`: `Monk::Presence.configure(db_name: :primary, grace: 20)`,
  and the commented example `presence-dots`;
- a migration for its three tables (`bin/setup_db` runs it);
- `app/views/presence/_dot.erb`, a dot for one person;
- `test/presence_test.rb`.

`bin/websocket_server` and `config.ru` start it when `config/presence.rb`
exists; there's nothing else to wire.

## Reading it

```ruby
Monk::Presence.status(["ann@example.com", "bob@example.com"])
# => {"ann@example.com" => {status: :online, last_seen_at: nil},
#     "bob@example.com" => {status: :offline, last_seen_at: 2026-11-13 10:02:11 UTC}}
Monk::Presence.online?("ann@example.com") # => true
```

Subjects are Monk::Auth's: the user's email. `status` is one query for all
the subjects you pass, so ask for the people on screen together, not one by
one. It works from any process (a route, a job, `bin/console`) and is right
even when every `bin/websocket_server` is down: a dead process's sockets
stop counting by themselves.

Render a page with the status it reads; use `on_change`, below, only to
update it.

## What each status means, measured

The browser tells the server when a page is hidden or shown, so a status
changes within a second or two of what the person did. When the socket
itself goes away depends on the platform:

| | Hidden (tab, app, lock) | Offline | Back |
|---|---|---|---|
| Desktop | away within a second | 20 s (the grace) after the tab or browser closes | online within a second |
| iPhone (Safari) | away within a second | about 24 s after locking: iOS drops a locked page's socket within a few seconds, then the grace | online 0.4 s after unlock (reconnect and resync) |
| Android (Chrome) | away within a second | when Chrome drops the socket: it can stay away for hours in a background tab; about 5 minutes on a locked phone, depending on its power settings | online within a second |

Measured on 2026-11-13 against a scaffolded app. So:

- **Away isn't "about to go offline".** On Android a hidden page keeps its
  socket, and Chrome answers the server's pings, so it reads away for as
  long as Chrome keeps it.
- **Offline isn't "unreachable".** A locked iPhone is offline within half a
  minute, but can still get a push notification. Telling the two apart is
  what notifications are for, not the socket.
- **Visible isn't "at the keyboard".** An unattended desktop tab reads as
  online. Idle detection is out of scope.
- **Several tabs or devices are one person**, online if any page is
  visible, away if all are hidden.
- **The grace** (`grace:`, 20 s) keeps a person as they were after their
  last page closes: a phone switching networks, or a deploy restarting
  `bin/websocket_server` and every page reconnecting, changes nobody's
  status.

Only signed-in sockets count: a visitor is never online. With Live, a page
counts as hidden until its first ping, sent the moment it connects while
visible, so a hidden tab reconnecting doesn't read as online. A socket that
isn't a Live page (an `app/sockets` handler) counts as visible while open.

## Reacting to a change: `on_change`

```ruby
# config/presence.rb
module AppPresence
  CHANGED = proc do |changes|
    # {"ann@example.com" => {status: :away, last_seen_at: nil}, ...}
  end
end
Monk::Presence.on_change(&AppPresence::CHANGED)
```

It runs in `bin/server`, with every person whose status changed in one
call. Among several `bin/server` processes (or hosts, or pods), one reacts
at a time, elected through Postgres; when it stops, another takes over
within 5 s (about 25 s if its host vanished without closing its
connection). The `bin/websocket_server` processes only detect changes and
signal them; they never run your code.

- **Its block runs in its own Ractor**: build it in a module, as Live's
  rules are. It sees no request, params or session.
- **At most once per change.** A change that happens while no `bin/server`
  runs is never reported. Live pages catch up when they reconnect; anything
  else should read `status` when it needs to.
- **An error in it is logged**, and the next change is still handled.

### Pushing to pages: one message per batch

The example `presence-dots` in `config/presence.rb`, uncommented, pushes
each change to every page showing those people:

```ruby
module AppPresence
  CHANGED = proc do |changes|
    changes.each_slice(50) do |slice|
      Monk::Live.batch("presence") do |batch|
        slice.each do |subject, change|
          batch.patch(to: AppPresence.dots(subject), partial: "presence/_dot", subject: subject,
            status: change[:status],)
        end
      end
    end
  end

  # Every dot of one person on a page, as a CSS selector.
  def self.dots(subject) = %([data-presence="#{subject.gsub(/["\\]/) { "\\#{it}" }}"])
end
Monk::Presence.on_change(&AppPresence::CHANGED)
Monk::Live.authorize("presence", &Monk::Live::ALLOW_ALL)
```

with, in a page,

```erb
<ul <%= live_topic "presence" %>>
  <% Monk::Presence.status(emails).each do |email, status| %>
    <li><%= render "presence/_dot", subject: email, status: status[:status], layout: false %> <%= email %></li>
  <% end %>
</ul>
```

One `Live.batch` per 50 people, not one `Live.patch` per person: a burst of
changes (a `bin/websocket_server` that died, a reconnect wave) then stays
a handful of messages. Patches sent one by one can outrun the `:notify`
pool that publishes them, which drops what it can't queue (1000 waiting):
in a measured burst of 20K patches under load, 416 were dropped. And over
Postgres a message is capped at 8 KB, about 50 dots.

`ALLOW_ALL` lets every signed-in person see everyone's dots. In a real app,
publish to the topics your pages already use (a contact list, a chat's
members) and authorize those.

## Deploying

- **`bin/server` needs a direct connection to Postgres** for its reactor:
  `LISTEN` and the election's session lock don't work through PgBouncer in
  transaction mode.
- **Connections:** each `bin/server` process opens one more (its reactor's,
  holding the lock or waiting for it), and the one reacting one more again
  for reading statuses: N processes, N + 1. Each `bin/websocket_server`
  process opens one for its counts.
- **Reads go to the primary database.** The per-process tables are
  `UNLOGGED` (rewritten every second, not worth the WAL), so they aren't on
  replicas, and after a Postgres crash they come back empty; each
  `bin/websocket_server` writes its counts again on its next tick.
- **A deploy** restarting `bin/websocket_server` changes nobody's status, if
  pages reconnect within the grace (they do at once). Restarting
  `bin/server` only moves the reaction to another process.
- **The proxy** in front of `bin/websocket_server` must keep idle WebSockets
  open past 25 s, the ping interval: the [deploying guide](deploying.md)
  covers it.

## What it costs

A `bin/websocket_server` process writes what changed once a second, in one
statement, whatever the number of sockets that changed; it settles
transitions in one transaction, which notifies `bin/server` of the people
who changed (one notification per 8 KB of their names, Postgres's limit). A
wave of 25K connects is a few statements a second, not 25K (the connect
benchmark, `bin/benchmark_ws_connect --presence`).

## Testing

`test/presence_test.rb` reads someone who has no page open as offline.
Readers need only the tables, so a test can call `Monk::Presence.status`
directly. To test an `on_change` block, call it: it's a proc taking the
changes.
