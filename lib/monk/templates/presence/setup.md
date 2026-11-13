## presence

Whether a signed-in person has a page open: online, away (only hidden
pages, like a phone in a pocket) or offline. `bin/websocket_server`
counts its sockets and writes them to Postgres every few seconds;
`Monk::Presence.status` reads them from any process. A migration
creates the `monk_presence*` tables: run `bin/setup_db` and
`DB_NAME={{app}}_test bin/setup_db` (postgres, above).

Only signed-in sockets count (auth, above). With live, a page counts as
away until its first ping, a moment after it opens.

### Reacting to a change

`Monk::Presence.on_change` in `config/presence.rb` runs in `bin/server`
each time some people's status changes: `config.ru` starts it. Among
several `bin/server` processes, one reacts at a time; if it stops,
another takes over within seconds. The example `presence-dots` pushes
each change to the pages showing those people, with live.

### Before production

- The process reacting to changes holds its own Postgres connection,
  and needs a direct one: not through PgBouncer in transaction mode.
  Each `bin/server` process opens one more, plus one for reading the
  statuses when it reacts.
- A person stays as they were for `grace:` seconds (20) after their last
  page closes, so a deploy restarting `bin/websocket_server` changes
  nobody's status.

### Check it works

1. `bundle exec rake test` runs `test/presence_test.rb`: someone with no
   page open reads as offline.
2. By hand, with `bin/server` and `bin/websocket_server` running: log in
   (auth, above) and open a page that connects to the WebSocket (with
   live, any page with `live_topic`). Then, in `bin/console`:

   ```ruby
   Monk::Presence.status(["you@example.com"])
   # => {"you@example.com" => {status: :online, last_seen_at: nil}}
   ```

   Hide the tab (or lock the phone) and it reads `:away` within a
   second or two; close it and, after the grace, `:offline` with
   `last_seen_at`. A locked iPhone goes `:offline` too, about 25 s after
   locking: iOS drops a locked page's connection.
3. The example: uncomment `presence-dots` in `config/presence.rb`, put
   `<div <%= live_topic "presence" %>><%= render "presence/_dot", subject: "you@example.com", status: :offline, layout: false %></div>`
   in a page, and restart both servers. Open it in one browser, and log
   in as that person in another: the dot changes by itself.
